# Plan 17 — Human-memory model: tiers, forgetting & "dreaming"

**Theme:** Smarter memory · **Effort:** L · **Depends on:** 02 (reinforcement), 03 (dedup), 04 (supersede), 10 (SQLite)

## Goal

Model the memory store on human memory. New knowledge enters a fragile **short-term (episodic)**
tier and must *earn* its way into a durable **long-term (semantic)** tier. A periodic offline
**"dream"** pass — run when idle / overnight / on demand — does what sleep does to memory:
replays recent episodics, **abstracts** clusters of specifics into general schemas, **recategorizes**
mis-binned notes, **promotes** what's been reinforced, and **forgets** what hasn't (archive → purge).

## Why

Today every distillation is born permanent in one flat store with no forgetting. The measured
result (June 2026, 212 memories): **70% came from the one-time Claude import**, **61% were dumped
in a single `Projects` bucket**, **62% had never once surfaced**, and **0 had ever been archived**.
Decay (plan 02) only relaxes `weight` back toward base `importance` — it never demotes, evicts, or
reorganizes. So clutter is immortal and the `Projects` category is a junk drawer.

A one-shot cleanup (see "Prior art" below) already proved the prompts: it recategorized 41 imports
and archived 22 ephemeral dev-trivia memories. This plan makes that a standing, automatic system.

## Current state (grounded)

- `Memory` (Models.swift:104) has `importance`, `weight`, `hitCount`, `lastSurfaced`, `superseded`
  / `supersededBy` / `history`, `pinned`, `userEdited`, `source`. **No tier, no retention score.**
- `Reinforcement` (Reinforcement.swift) decays `weight` only; `decayWeights` (AppState.swift:1324)
  never archives.
- `Consolidator.maintain` (Maintenance.swift:196) does **pairwise** dedup + supersede over
  candidate pairs from `entityBuckets` / `semanticBuckets`. No *cluster → gist* abstraction.
- `maintainNow` (AppState.swift:1271) is triggered every `dedupeEveryNNew` (25) new memories.
- Import (`ContextImporter`) lands everything as permanent memories; `category(forType:)` maps
  Claude `type: project` → `Projects`, which is the root of the junk-drawer problem.
- `superseded` is already the soft-archive: `candidatePairs` skips it, the graph view hides it,
  `restoreMemory` un-archives. **This is the forgetting primitive — reuse it.**

## Design

Three additions: a **tier** field, a **retention** score with a forgetting curve, and a **dream**
orchestrator that reuses `maintain` + adds abstraction + applies promotion/forgetting.

### 1. Data model (Models.swift)

```swift
enum MemoryStage: String, Codable { case episodic, semantic }

var stage: MemoryStage = .episodic   // new + imported memories start here
var retention: Double = 1.0          // forgetting-curve strength; ≥0
var archivedAt: Date? = nil          // set when retention falls below floor (archive→purge clock)
```

Codable ignores unknown keys, so existing rows decode with the defaults — no migration needed.
Live distillations and imports are born `.episodic`. (Decisions, People, and user-pinned/edited
memories may be born `.semantic` — durable by nature.)

### 2. Forgetting curve (extend Reinforcement.swift)

Generalize decay from `weight` to a `retention` strength (Ebbinghaus + spaced repetition):

```swift
// retention decays with time; surfacing resets the clock and raises the ceiling.
static func retained(_ r: Double, lastRef: Date, now: Date,
                     halfLifeDays: Double, importance: Int, linkCount: Int) -> Double {
    let days = now.timeIntervalSince(lastRef) / 86_400
    // well-connected, important memories decay slower (longer effective half-life)
    let hl = halfLifeDays * (1 + 0.15 * Double(importance) + 0.05 * Double(min(linkCount, 10)))
    return r * pow(0.5, days / max(1, hl))
}
```

- Surfacing (the existing reinforcement hook) bumps `retention` back up (spaced repetition).
- `pinned` / `userEdited` are exempt (retention pinned at max), matching `decayWeights` today.

### 3. The dream pass (new: Dream.swift, orchestrating Consolidator)

A single async sweep, idempotent, run on the cadence in §4:

1. **Promote.** Episodic memories that are durable by signal — `hitCount ≥ N`, or `importance ≥ 4`,
   or in {Decisions, People, Preferences} — flip to `.semantic` and get retention floored high.
2. **Abstract (the new LLM step).** Cluster *episodic* memories by shared entity / embedding
   (reuse `entityBuckets` + `semanticBuckets`, Maintenance.swift:113/142). For each dense cluster,
   ask the model to write **one consolidated semantic memory** capturing the durable gist, linking
   out to the specifics (which become supporting episodics or are archived). This is what
   permanently dissolves dumping grounds like `Projects`.
3. **Recategorize.** Same LLM call fixes mis-binned memories against the taxonomy (see §5).
4. **Dedup + supersede.** Call existing `Consolidator.maintain` on candidate pairs (no new code).
5. **Forget.** Apply the §2 curve. Episodic memories below `retentionFloor` → set `superseded =
   true`, `archivedAt = now`, history note. **Purge:** archived memories with
   `archivedAt < now − purgeGraceDays` and `!pinned && !userEdited` are hard-deleted
   (`deleteMemory`). Semantic memories are never auto-purged — only demoted to episodic first.

Prompts mirror `maintainSystem` / `importSystem`: terse, JSON-only, conservative ("when unsure,
keep / distinct"). Abstraction + recategorize run on the cheap model (`gateModel`, Haiku).

### 4. Scheduling (AppState)

- **Idle / overnight trigger.** Run when the app has been idle (no capture) for ≥ N minutes, at
  most once per `dreamMinHours`. Guard like `maybeDecay` (a dated `UserDefaults` key). Never run
  while consolidating/importing/deduping (the existing `isConsolidating` etc. guards).
- **Manual.** A "Dream now" button (Panes) for on-demand consolidation, with a progress/result
  line like `maintainNow` ("Dreamt: 6 abstracted, 3 promoted, 11 archived, 2 purged").
- Replaces the every-25-new `maintainNow` trigger with the unified dream cadence (or keeps a light
  dedup on that trigger and the full sweep on idle).

### 5. Taxonomy fix (Models.swift Category)

Add a category so engineering reference stops polluting `Projects`:

```swift
case reference = "Reference"   // durable technical/how-it-works facts (was over-loading Facts/Projects)
```

with a `symbol`/`hue`. Update `ContextImporter.category(forType:)` so Claude `type: reference` →
`Reference` and only genuine ongoing work → `Projects`. (The dream pass back-fills existing rows.)

### 6. Import routing (ContextImporter)

Claude **Code** per-project notes are dev working-memory, not life memory. On import: tag them
`.episodic` with lower base importance and a shorter half-life, so anything that never resurfaces
self-forgets within a cycle or two instead of living forever. Optionally summarize-on-import rather
than storing 3,000-char notes verbatim (imported memories averaged 13× longer than live ones).

## Files touched

- `Models.swift` — `MemoryStage`, `stage`/`retention`/`archivedAt`, `Category.reference`.
- `Reinforcement.swift` — `retained(...)`; surfacing bumps retention.
- `Dream.swift` (new) — abstraction + recategorize prompts; orchestration over `maintain`.
- `Maintenance.swift` — expose cluster grouping for the abstraction step (helpers already exist).
- `AppState.swift` — `dreamNow()`, idle/overnight scheduler, promotion + forget + purge application.
- `Config.swift` — `dreamEnabled`, `dreamMinHours`, `retentionFloor`, `purgeGraceDays`,
  `dreamIdleMinutes`, `episodicHalfLifeDays`.
- `Panes.swift` — "Dream now" control + result surfacing; archived/purged visibility.

## Config additions

```jsonc
"dream": true,               // master switch
"dreamMinHours": 12,         // min gap between automatic dreams
"dreamIdleMinutes": 20,      // idle before an automatic dream may run
"retentionFloor": 0.15,      // below this an episodic memory is archived
"purgeGraceDays": 90,        // archived → hard-deleted after this if untouched
"episodicHalfLifeDays": 10   // fast curve for fresh/imported episodics (vs semantic ~30)
```

## Edge cases

- **Never forget user-owned.** `pinned` / `userEdited` exempt from archive *and* purge throughout.
- **Reversibility.** Archive reuses `superseded`, so `restoreMemory` already un-forgets. Purge is
  the only destructive step — gated by the grace window + a one-time backup of the data dir.
- **Abstraction must not lose facts.** Keep source memories (archived, restorable) until the gist
  has surfaced at least once; conservative merge, like `applyMerges` union semantics.
- **Idempotent.** Re-running a dream with no changes is a no-op (promotion/recategorize are
  fixed-points; retention only moves with time).
- **Cost.** Abstraction/recategorize are batched cheap-model calls, gated to dense clusters only;
  the whole sweep is O(clusters), not O(n²) — reuses the sub-quadratic blocking from plan 03.

## Testing

- `Reinforcement.retained` curve: decay monotonic, importance/links lengthen half-life, surfacing
  resets (pure, unit-testable like existing `decayed` tests).
- Promotion/forget/purge transitions on a synthetic graph (no LLM): correct stage flips, archive at
  floor, purge only past grace, user-owned never touched.
- Abstraction merge preserves entities/links/provenance (extend `applyMerges` tests).
- Recategorize parser tolerates fenced/:noisy JSON (reuse `parseJSON`).

## Risks

- **Over-forgetting.** Mitigated by conservative floor, episodic-only archiving, grace-window purge,
  and full reversibility until purge. Ship with archive-only (no purge) behind a flag first.
- **Bad abstraction.** A gist that drops a real fact. Mitigated by keeping sources archived and a
  "show sources" affordance; start with recategorize+forget (already proven) before enabling merge.

## Prior art — the one-shot cleanup (already run, June 2026)

A scratch dry-run proved the recategorize + forget prompts on the real store before this plan:
recategorized 41 Claude imports (Projects 116→77, surfacing real Decisions=28 / Facts=40) and
soft-archived 22 ephemeral dev-trivia memories, each with a transparent `history` note. That logic
is the seed for `Dream.swift` §2–3 and §5; this plan generalizes it from a manual script into the
standing episodic→semantic lifecycle.

## Status

Shipped: tiers + retention curve, recategorize/triage, lifecycle (promote/decay/archive/demote/
purge), abstraction (cluster→gist with subsumed-source archiving, `dreamAbstract` flag), idle
scheduler + "Dream" button, tolerant `Memory` decoding so schema additions never wipe the store.
Possible follow-ups: a "show sources" affordance on a gist; smarter cluster selection (embedding
buckets in addition to entity buckets); folding the existing `maintain` dedup pass into the dream.

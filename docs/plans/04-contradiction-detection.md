# Plan 04 — Contradiction detection & supersede

**Theme:** Smarter memory · **Effort:** M · **Depends on:** 03 (shares candidate-pair + adjudication machinery)

## Goal

When new speech updates a fact that an existing memory records ("Actually the deadline moved to
Oct 15"), recognise it as a *change*, supersede the stale memory, and keep a short history —
rather than silently storing two contradictory memories.

## Why

Right now a changed fact either (a) updates the memory if the LLM happens to reuse the exact title
(Consolidator.swift:269), or (b) creates a second memory that contradicts the first. Case (b)
leaves the graph holding both "deadline Sept 30" and "deadline Oct 15", and surfacing/briefing may
show the wrong one. Detecting supersession makes the memory trustworthy for decisions and dates —
exactly the high-value categories the Surfacer already weights up (tasks, decisions, questions).

## Current state

- Consolidation has no notion of "this contradicts that"; merge is title-keyed.
- Memories have `created`/`updated` but no version history.
- Plan 03 introduces candidate-pair generation + a cheap Haiku adjudication call — reuse both.

## Design

### Detection

Piggyback on plan 03's candidate pairs (high-similarity memory pairs), but ask a different
question of the LLM during the dedupe/maintenance pass — distinguish three relations:

```
For each pair, classify: "duplicate" (same fact) | "supersedes" (B updates/overrides A,
e.g. a changed date/decision/status) | "distinct". For "supersedes", say which is newer
using the timestamps given. Output JSON:
{"pairs":[{"pair":0,"relation":"supersedes","newer":"b","note":"deadline changed Sep 30 -> Oct 15"}]}
```

New transcript-driven contradictions are the common case, so also run a lighter check at
consolidation time: when `merge` creates a new memory that shares an entity with an existing one
in a "fact/decision/task" category, flag the pair for the next maintenance pass rather than
adjudicating inline (keeps consolidation latency unchanged).

### Supersede action

For a confirmed `supersedes`:
- The newer memory becomes canonical. The older one is **archived**, not deleted: set
  `superseded = true` and `supersededBy = <newer id>`.
- Archived memories are excluded from surfacing, briefing, and the default Memory pane, but remain
  visible under a "History" disclosure on the canonical memory (ties into provenance, plan 05).
- Append a one-line `historyNote` to the canonical memory (e.g. "Was: deadline Sept 30 (until
  2026-06-20)").

### Data model additions (Models.swift)

```swift
var superseded: Bool = false
var supersededBy: UUID? = nil
var history: [String] = []     // short human notes of what changed, newest last
```

## Files touched

- `Sources/Nemo/Models.swift` — three defaulted fields.
- `Sources/Nemo/Consolidator.swift` — extend the maintenance pass (plan 03) to classify
  relations; flag candidate contradictions at merge time.
- `Sources/Nemo/AppState.swift` — apply supersede (archive + history), exclude `superseded` from
  `memories(in:)`, `refreshSurfaced`, briefing inputs.
- `Sources/Nemo/Surfacer.swift` — skip `superseded` memories (or let `AppState` pre-filter).
- `Sources/Nemo/Briefer.swift` — exclude archived from inputs.
- UI (Panes.swift) — "History" disclosure on a memory; an "Archived" filter chip.
- `Sources/Nemo/Config.swift` — `contradictionDetectionEnabled` (default true).

## Edge cases

- **Genuinely distinct facts that share an entity** (two deadlines for two projects): the LLM
  classifies "distinct"; the entity heuristic only *nominates*, never decides.
- **Wrong supersede:** because we archive rather than delete, recovery is trivial — surface an
  "Undo / restore" affordance on the archived entry.
- **Chains:** A superseded by B superseded by C — always resolve `supersededBy` transitively to
  the live head when rendering history.
- **Backward compat:** defaulted fields; old data loads unchanged.

## Testing (see plan 07)

- Unit: applying a `supersedes` verdict archives the older memory, sets `supersededBy`, appends a
  history note, and removes it from `memories(in:)` output.
- Unit: transitive resolution of a supersede chain returns the live head.
- Manual: state a fact, then contradict it in later speech; confirm the old one archives with a
  readable history note and the new one surfaces.

## Risks / open questions

- LLM mis-classification between "supersedes" and "distinct" is the main risk; conservative
  default (treat ambiguous as "distinct", keep both) plus easy undo keeps it safe.
- Decide whether supersession can apply across long time gaps automatically or should require the
  shared-entity + same-category nomination to fire (recommended: require it).

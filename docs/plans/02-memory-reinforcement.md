# Plan 02 — Memory decay & reinforcement

**Theme:** Smarter memory · **Effort:** S · **Depends on:** —

## Goal

Let importance reflect how a memory actually behaves over time: things that keep coming up get
more prominent; things that never resurface fade. Today `importance` is set once at
consolidation (Consolidator merge, Consolidator.swift:264) and frozen forever.

## Why

A frozen importance score means the memory graph can't learn from use. A fact mentioned in every
meeting and a one-off aside can carry the same `importance: 3`. Reinforcement makes surfacing and
the morning briefing prioritise what's genuinely live, with zero LLM cost — it's pure bookkeeping
off signals we already produce (surfacing hits, manual marks, briefing inclusion).

## Current state

- `Memory` has `importance: Int` (1–5), `created`, `updated` (Models.swift:108–112).
- `Surfacer.rank` already nudges score by `0.18 * importance` (Surfacer.swift:107).
- `refreshSurfaced` (AppState.swift:369) computes hits every finalized segment — this is the
  natural place to record "this memory was relevant just now".
- Merge `max`'s importance on update (Consolidator.swift:273) so it only ever ratchets up.

## Design

Add lightweight usage fields to `Memory` and a decay function that runs on a slow cadence.

### Data model additions (Models.swift)

```swift
var hitCount: Int = 0          // times surfaced as relevant
var lastSurfaced: Date? = nil  // most recent surfacing
var weight: Double = 0.0       // derived reinforcement signal, separate from `importance`
```

Keep `importance` as the LLM/user-set base (1–5). Introduce `weight` as the *learned* component
so we never silently overwrite a user's pin (plan 05) or the model's judgement. Effective
ranking importance = `Double(importance) + weight`, clamped.

### Reinforcement (cheap, inline)

In `refreshSurfaced`, when a memory enters `hits` for the first time in a surfacing episode
(i.e. it wasn't already in `surfaced`), bump:

```swift
mem.hitCount += 1
mem.lastSurfaced = now
mem.weight = min(2.0, mem.weight + 0.15)   // each fresh surfacing adds a little, capped
```

Persist on a throttle (e.g. coalesce writes; don't `saveMemories` on every 12s tick). Manual
mark of a memory (plan 05 pin) and inclusion in a spoken answer (plan 11) also reinforce.

### Decay (slow, periodic)

A daily pass (fold into `maybeAutoBrief`'s once-per-day cadence, AppState.swift:416, or a dated
guard in `init`) applies exponential decay to `weight` only:

```swift
// half-life ~30 days; never touches user `importance` or pinned memories
let days = now.timeIntervalSince(m.lastSurfaced ?? m.updated) / 86_400
m.weight *= pow(0.5, days / 30)
if m.weight < 0.01 { m.weight = 0 }
```

### Use the signal

- `Surfacer.rank`: replace `0.18 * Double(mem.importance)` with
  `0.18 * effectiveImportance(mem)`.
- `Briefer` (Briefer.swift) and Memory pane sort: order by `effectiveImportance` so the briefing
  leads with what's currently live.

## Files touched

- `Sources/Nemo/Models.swift` — three new fields (all defaulted → existing JSON decodes fine).
- `Sources/Nemo/AppState.swift` — reinforce in `refreshSurfaced`; daily decay pass; throttled save.
- `Sources/Nemo/Surfacer.swift` — use effective importance.
- `Sources/Nemo/Briefer.swift` — order by effective importance (small).
- `Sources/Nemo/Config.swift` — `reinforcementEnabled` (default true), `decayHalfLifeDays`.

## Edge cases

- **Backward compat:** new fields default to 0/nil, so old `memories.json` loads unchanged and
  starts accumulating from first surfacing.
- **Pinned memories** (plan 05): decay skips them; their `importance` is user-authoritative.
- **Write amplification:** never persist on the 12s prune tick; coalesce reinforcement writes
  (dirty flag → save at next consolidation, which already writes memories).
- **Clock skew / sleep:** decay uses elapsed wall-time, naturally robust to the app being closed.

## Testing (see plan 07)

- Unit: decay math — a memory untouched for one half-life has its `weight` halved; `importance`
  untouched.
- Unit: reinforcement caps at the ceiling after repeated hits.
- Unit: `effectiveImportance` ordering changes Memory-pane sort as expected.

## Risks / open questions

- Tuning the increment/half-life needs a little real-world calibration; expose both in config.
- Don't let `weight` leak into the *displayed* 1–5 importance badge — show `importance` in the UI,
  use `effectiveImportance` only for ranking, to keep the badge meaningful to users.

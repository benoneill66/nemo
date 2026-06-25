# Plan 01 — Semantic surfacing via `NLEmbedding`

**Theme:** Smarter memory · **Effort:** M · **Depends on:** — · **Unblocks:** 11 (RAG Hey Nemo)

## Goal

Make the real-time "Relevant now" strip surface memories that are *conceptually* related to
what's being said, not just lexically. "We should review Q3 numbers" should surface the
memory titled "Quarterly planning deadline" even with zero shared words.

## Why

`Surfacer.rank` (Surfacer.swift:63) scores purely on token/entity/title overlap. It's fast and
free but blind to synonymy and paraphrase — the most common way the same topic recurs in
speech. This is the single highest-leverage upgrade to Nemo's core promise ("surface what
matters, in the moment"). Apple's `NLEmbedding` (in the `NaturalLanguage` framework) gives us
sentence/word embeddings fully on-device, with **no new dependency and no network egress**, so
it fits the architecture cleanly.

## Current state

- `Surfacer` is a pure `enum` with a single `rank(recent:memories:minScore:limit:)` entry point.
- `AppState.refreshSurfaced` (AppState.swift:369) builds `recentText` from the last ~12 segments
  within `surfaceWindowSeconds`, calls `Surfacer.rank`, then merges/decays into `surfaced`.
- Memories have `title`, `content`, `entities` (Models.swift:102). No vectors stored.
- Config knobs already exist: `surfaceWindowSeconds`, `surfaceTTLSeconds`, `surfaceMax`,
  `surfaceMinScore` (Config.swift:42–50).

## Design

### 1. `EmbeddingIndex` — on-device vector store

New file `Sources/Nemo/EmbeddingIndex.swift`. A small actor-free `final class` (used on the
main actor) that owns one vector per memory and answers cosine-similarity queries.

```swift
import NaturalLanguage

final class EmbeddingIndex {
    private let model = NLEmbedding.sentenceEmbedding(for: .english)
    private(set) var vectors: [UUID: [Double]] = [:]   // memory id -> unit vector

    var isAvailable: Bool { model != nil }

    /// Text we embed for a memory: title carries most signal, content adds nuance.
    static func text(for m: Memory) -> String { m.title + ". " + m.content }

    func vector(for text: String) -> [Double]? {
        guard let model, let v = model.vector(for: text) else { return nil }
        return normalize(v)        // store unit vectors so similarity == dot product
    }

    /// Rebuild/refresh vectors for the given memories. Only (re)embeds entries whose
    /// content hash changed, tracked via `hashes`. Cheap to call after every consolidation.
    func sync(_ memories: [Memory]) { /* embed missing/changed, drop deleted */ }

    /// Top-k memory ids by cosine similarity to `query`, with scores in [-1, 1].
    func search(_ query: String, limit: Int) -> [(id: UUID, score: Double)] { /* dot products */ }
}
```

Notes:
- `NLEmbedding.sentenceEmbedding(for:)` can be `nil` if the language asset isn't present.
  Treat `isAvailable == false` as "fall back to lexical only" — never a hard failure.
- Vectors are ~512 doubles each. 10k memories ≈ 40 MB resident — fine. Persist to
  `embeddings.json` (or a compact binary blob) via `Store` so we don't re-embed every launch.
  Embed lazily on first use if the cache is missing.

### 2. Hybrid scoring in `Surfacer`

Keep `Surfacer.rank` as the lexical scorer. Add a new combiner so semantic and lexical signals
reinforce rather than replace each other (lexical is precise on names/IDs; semantic is precise on
topics).

```swift
extension Surfacer {
    struct Scored { var memory: Memory; var score: Double; var matched: [String]; var reason: String }

    /// Blend lexical hits with semantic neighbours. `semantic` is (id -> cosine) for the
    /// recent text, already filtered to >= semanticFloor by the caller.
    static func rankHybrid(recent: String, memories: [Memory],
                           semantic: [UUID: Double],
                           lexicalWeight: Double = 1.0, semanticWeight: Double = 4.0,
                           minScore: Double, limit: Int) -> [Scored]
}
```

Combination: `final = lexicalScore + semanticWeight * max(0, cosine - semanticFloor)`.
`semanticFloor` ≈ 0.30 drops weak neighbours (sentence embeddings rarely go below ~0.2 for
unrelated text). A memory that only matches semantically still surfaces, with reason
"Related: <its title>"; a lexical+semantic match ranks highest. Retain the category weighting
and importance nudge already in `rank`.

### 3. Wire into `AppState`

- Add `private let embeddings = EmbeddingIndex()`.
- After every successful consolidation/import (where `self.memories` is reassigned), call
  `embeddings.sync(self.memories)`. Also `sync` once in `init` after load.
- In `refreshSurfaced`, compute `semantic = embeddings.search(recentText, limit: 20)` →
  dict, pass to `rankHybrid`. If `!embeddings.isAvailable`, keep calling the old `rank`.
- `deleteMemory` (AppState.swift:529) should also drop the vector (handled by next `sync`,
  but eager removal avoids a stale hit before the next consolidation).

## Files touched

- **New:** `Sources/Nemo/EmbeddingIndex.swift`
- `Sources/Nemo/Surfacer.swift` — add `rankHybrid` + `Scored`.
- `Sources/Nemo/AppState.swift` — own the index, sync on mutation, use in `refreshSurfaced`.
- `Sources/Nemo/Store.swift` — `loadEmbeddings()` / `saveEmbeddings()` for the vector cache.
- `Sources/Nemo/Config.swift` — `semanticSurfaceEnabled` (default true), `semanticWeight`,
  `semanticFloor`.

## Data / config changes

- New cache file `~/.config/nemo/data/embeddings.json` (or `.bin`). Not user-facing; safe to
  delete (rebuilds on next launch). Document in README's data-layout section.
- No change to `Memory` shape — vectors live in the side index keyed by id, so memory JSON stays
  human-readable and diff-friendly.

## Edge cases

- **Language asset missing** → `isAvailable == false` → lexical-only, log once in `statusText`.
- **Non-English speech** → sentence embedding is English-only here; lexical path still works. A
  follow-up could pick `NLEmbedding` by detected language.
- **Empty `recentText`** → return `[]` (already guarded in `rank`).
- **Very short memories** (one-word title, empty content) embed fine but may be noisy; the
  `semanticFloor` and existing `minScore` keep them out.
- **Embedding drift after edits** (plan 05) → `sync` re-embeds on content-hash change.

## Testing (see plan 07)

- Unit: `rankHybrid` ordering with synthetic `semantic` dicts — a pure-semantic match surfaces,
  a lexical+semantic match outranks a lexical-only one, sub-floor cosines are ignored.
- Unit: `EmbeddingIndex.sync` is incremental (unchanged memories keep their vector object;
  deleted ids are dropped).
- Manual: speak a paraphrase of an existing memory's topic; confirm it surfaces where the old
  lexical engine wouldn't. Add a known before/after example to the PR description.

## Risks / open questions

- `NLEmbedding` sentence vectors are decent but not SOTA; tune weights against real transcripts
  before shipping. Keep `semanticSurfaceEnabled` so it can be turned off if it adds noise.
- First-call latency to load the embedding model (~tens of ms) — warm it on a background task at
  launch so the first segment doesn't stutter.

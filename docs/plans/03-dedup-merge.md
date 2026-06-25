# Plan 03 — Deduplication / merge pass

**Theme:** Smarter memory · **Effort:** M · **Depends on:** — (pairs well with 01's embeddings)

## Goal

Stop the graph from accumulating near-duplicate memories of the same fact over weeks
("Q3 deadline is Sept 30" / "Quarterly deadline end of September" / "Sept 30 is the Q3 cutoff").
Periodically detect and merge duplicates into one canonical memory.

## Why

Consolidation merges only on **exact lowercased title match** (Consolidator.swift:253, 269). Any
paraphrased title creates a new memory. Over time this bloats the Memory pane, dilutes surfacing
(the same fact competes with itself), and makes the briefing repetitive. A cheap periodic merge
keeps the graph crisp. The gate model (Haiku) is already wired in and cheap enough to adjudicate
borderline cases.

## Current state

- Merge logic lives in `Consolidator.merge` (Consolidator.swift:249); linking by shared entity in
  `linkByEntity` (Consolidator.swift:311).
- `Consolidator.gate` (Consolidator.swift:133) shows the pattern for a cheap Haiku JSON call.
- No dedup exists; nothing collapses two existing memories.

## Design

A two-stage pass: **candidate generation** (free, on-device) → **adjudication** (cheap LLM, only
on candidates).

### Stage 1 — candidate pairs (on-device)

Find pairs likely to be duplicates without an LLM:
- **Embedding cosine ≥ 0.82** (if plan 01's `EmbeddingIndex` is present) — strongest signal.
- **Shared-entity + token-Jaccard** fallback when embeddings unavailable: same dominant entity
  AND title/content token Jaccard ≥ 0.6.
- Only compare within a reasonable window (same category or shared entity) to stay O(n·k) not
  O(n²); for typical graphs n is small enough that full pairwise is fine too.

### Stage 2 — adjudicate + merge (LLM, batched)

Send the candidate pairs to Haiku in one call:

```
You are deduplicating a personal memory graph. For each numbered pair, decide if they
describe the SAME underlying fact/item and should be merged. If yes, return the merged
title + content (preserve every distinct detail; prefer the more specific wording).
Output ONLY JSON: {"merges":[{"pair":0,"title":"...","content":"...","keep":"a|b"}]}
```

For each approved merge:
- Keep one memory id (the older / more-linked one → `keep`), rewrite its title+content to the
  merged version, union `entities`, union `links`, `max` importance, sum `hitCount` (plan 02).
- Re-point every other memory's `links` from the dropped id to the kept id.
- Delete the dropped memory (reuse the link-cleanup in `AppState.deleteMemory`, AppState.swift:529).
- Re-embed the kept memory (plan 01 `sync`).

Expose `Consolidator.dedupe(memories:model:) async throws -> Output` mirroring the existing
`Output` shape (memories, created=0, updated=mergeCount) so `AppState` handles it like
consolidation.

### Scheduling

- Run after consolidation when memory count crossed a threshold since the last dedupe (e.g. +25
  new), or on a daily cadence alongside the briefing. Never run mid-meeting.
- Guard with `isConsolidating`-style flag (`isDeduping`) so it can't overlap other LLM work.

## Files touched

- `Sources/Nemo/Consolidator.swift` — `candidatePairs(...)` (on-device) + `dedupe(...)` (LLM).
- `Sources/Nemo/AppState.swift` — `dedupeNow()`, scheduling, `isDeduping` flag, re-embed + save.
- `Sources/Nemo/EmbeddingIndex.swift` (plan 01) — reuse cosine for candidate generation.
- `Sources/Nemo/Config.swift` — `dedupeEnabled` (default true), `dedupeEveryNNew`, `dedupeCosine`.

## Edge cases

- **False merge risk:** require BOTH a strong candidate signal AND LLM approval; when the LLM is
  unsure it returns no merge. Log merges to `statusText` ("Merged 3 duplicate memories") so they're
  visible; provenance (plan 05) lets the user see what was folded in.
- **Link integrity:** after merge, ensure no memory links to a deleted id and no self-links
  (reuse/extend `Consolidator.link`).
- **Manually edited / pinned memories** (plan 05): never silently overwrite a user-edited memory's
  text — if either side is user-edited, merge into it but keep its wording as the base, or skip.
- **LLM failure:** skip the pass, keep everything (same fallback philosophy as `gate`).

## Testing (see plan 07)

- Unit: `candidatePairs` flags an obvious dup pair and ignores unrelated memories (with a stub
  cosine function and with the Jaccard fallback).
- Unit: merge bookkeeping — links repointed, entities/importance unioned, dropped id absent,
  no dangling links.
- Manual: seed two paraphrased memories, run `dedupeNow`, confirm one canonical result.

## Risks / open questions

- Aggressive thresholds could merge genuinely distinct facts (two people named "Alex"). Bias
  conservative; the entity check and LLM adjudication both guard this. Consider a short undo
  window or keeping the dropped memory's text in the kept memory's content until next dedupe.

# Plan 05 — Memory editing, pin & provenance

**Theme:** Trust & control · **Effort:** M · **Depends on:** — · **Unblocks:** 04, 11, 10

## Goal

Give the user direct control over the memory graph from the UI: edit a memory's title/content/
category, pin importance so automation won't override it, and tap any memory to see the exact
transcript it came from ("why is this here?").

## Why

This is an always-on recorder distilling your life with an LLM. Trust requires (1) the ability to
fix or remove what it got wrong, and (2) transparency about provenance. Today `deleteMemory`
exists (AppState.swift:529) but there is **no edit path** — correcting a memory means hand-editing
`memories.json`. And there's **no link from a memory back to its source segments**, so a
hallucinated or surprising memory can't be traced. Provenance is also a prerequisite for grounding
RAG answers (plan 11) and citing contradictions (plan 04).

## Current state

- `AppState`: `deleteMemory` (529), `toggleMark` (535), `clearTranscript` (542) exist. No memory
  edit/pin.
- `Memory` has no back-reference to source segments (Models.swift:102). Consolidator drops the
  segment→memory mapping after `merge` — the link is never recorded.
- Memory pane renders cards and linked memories (Panes.swift); no edit affordance.

## Design

### 1. Provenance capture (record at consolidation)

The expensive consolidation already knows which segments it distilled (`relevant` in
`runConsolidation`, AppState.swift:295). Capture the mapping so each created/updated memory keeps
the ids of the segments that fed it.

- Add `var sourceSegmentIds: [UUID] = []` to `Memory` (Models.swift).
- `Consolidator.merge` can't currently attribute *which* drafts came from *which* segments (the
  LLM returns drafts, not a segment map). Pragmatic approach: attribute **the whole batch** —
  pass the consolidated segment ids into `merge`, and for every memory created/updated this round,
  union in those ids (capped to, say, the most recent 20 to bound growth). This gives
  "this memory was last touched by these segments" — accurate enough for "show me what was said".
  A future refinement could ask the model to cite indices per draft.
- **Don't prune provenance segments away.** `pruneConsolidatedTranscript` (AppState.swift:345)
  currently drops consolidated, unmarked, non-meeting segments after the retention window. Keep
  any segment referenced by a memory's `sourceSegmentIds` (add a guard to the `removeAll`
  predicate), so "view source" never dead-ends. Bounded because provenance ids are capped.

### 2. Editing & pinning (AppState API)

```swift
func updateMemory(_ id: UUID, title: String?, content: String?, category: String?)
func setImportance(_ id: UUID, _ value: Int)      // 1...5
func setPinned(_ id: UUID, _ pinned: Bool)
func sourceSegments(for id: UUID) -> [TranscriptSegment]   // resolve sourceSegmentIds
```

- Add `var pinned: Bool = false` and `var userEdited: Bool = false` to `Memory`.
- `updateMemory` sets `userEdited = true`, refreshes `updated`, and (plan 01) triggers re-embed.
- `pinned` / `userEdited` are honoured by automation: decay (02) skips pinned; dedupe/supersede
  (03/04) never silently overwrite a `userEdited` memory's text.
- Editing a title must keep the title-keyed merge map consistent — consolidation keys on
  lowercased title (Consolidator.swift:253), so a user-renamed memory simply becomes the new key;
  no migration needed, but note it so the model updates the right one going forward.

### 3. UI (Panes.swift, Glass.swift styling)

- Memory card → tap opens a detail sheet: editable title (TextField), content (TextEditor),
  category (Picker over `Category.allCases`), importance (1–5 stepper/segmented), pin toggle.
- "Source" section in the detail sheet: list `sourceSegments(for:)` with timestamp + speaker name
  (`speakerName(_:)`), tappable to jump to the Sessions pane at that moment.
- Delete button (wire to existing `deleteMemory`) with confirm.
- A small pin glyph + "edited" indicator on cards in the list.

## Files touched

- `Sources/Nemo/Models.swift` — `sourceSegmentIds`, `pinned`, `userEdited`.
- `Sources/Nemo/Consolidator.swift` — thread consolidated segment ids into `merge`; union into
  touched memories.
- `Sources/Nemo/AppState.swift` — `updateMemory`, `setImportance`, `setPinned`, `sourceSegments`;
  protect provenance segments in `pruneConsolidatedTranscript`.
- `Sources/Nemo/Panes.swift` — memory detail/edit sheet + source list.
- `Sources/Nemo/Glass.swift` — any new card affordances (pin glyph) if needed.

## Edge cases

- **Edited then re-consolidated:** the model may try to "update" a memory the user rewrote. Honour
  `userEdited` — merge new *entities/links* but don't overwrite user title/content unless the user
  hasn't edited it. (Simplest: if `userEdited`, append new info to content only on explicit user
  action; otherwise leave text alone.)
- **Provenance after pruning meeting transcripts:** meeting segments are already kept forever, so
  meeting-sourced memories always resolve.
- **Deleted source segments (pre-feature memories):** `sourceSegments` returns what it can; show
  "source no longer retained" gracefully for empty results.
- **Backward compat:** all new fields defaulted.

## Testing (see plan 07)

- Unit: `updateMemory` sets `userEdited`, updates timestamp, preserves links/entities.
- Unit: provenance round-trip — consolidate a batch, assert created memories carry the batch's
  segment ids, and those ids survive a prune cycle.
- Unit: pinned memory is skipped by the decay pass (cross-check with plan 02).
- Manual: edit a memory, confirm it persists across relaunch and isn't clobbered by the next
  consolidation; tap "source" and see the originating speech.

## Risks / open questions

- The "whole-batch attribution" approximation can over-attribute (a memory shows a few unrelated
  sibling segments). Acceptable for v1; the per-draft citation refinement is the clean fix and can
  be a fast follow.
- Decide the provenance cap (suggest 20 ids/memory) to bound both JSON size and retained
  transcript.

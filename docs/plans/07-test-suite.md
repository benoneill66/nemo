# Plan 07 — Test target

**Theme:** Reliability · **Effort:** S · **Depends on:** — (do this first)

## Goal

Stand up an XCTest target and cover the pure, logic-heavy pieces that are easy to get subtly wrong
and currently have **zero** automated coverage: the surfacer scorer, the diarizer clustering math,
and the consolidator's JSON parsing/merge.

## Why

`swift build` is all CI checks today (`.github/workflows/ci.yml`). The riskiest logic — relevance
scoring, voice clustering, lenient LLM-output parsing, graph merging — is all pure and trivially
testable without audio, UI, or the network. A test target is cheap insurance that pays off the
moment plans 01–04 start changing `Surfacer` and `Consolidator`.

## Current state

- `Package.swift` (read: single `.executableTarget` named `Nemo`, no test target).
- Pure/near-pure units ready to test as-is:
  - `Surfacer.tokens`, `Surfacer.rank` (Surfacer.swift) — fully pure.
  - `Consolidator.parseJSON` / `parse` and `merge` (Consolidator.swift) — pure given inputs (note:
    currently `private`; expose via `@testable import` or a thin internal seam).
  - `SpeakerDiarizer` clustering / cosine (SpeakerDiarizer.swift) — pure math.
  - `AssistantRunner.spoken(from:)` and the stream-JSON delta parsers `textDelta` /
    `isContentBlockStop` (Assistants.swift) — pure, already `static`.

## Design

### Package wiring

```swift
// Package.swift
.testTarget(
    name: "NemoTests",
    dependencies: ["Nemo"],
    path: "Tests/NemoTests"
)
```

Use `@testable import Nemo` so `private static` helpers (`parseJSON`, `merge`, `buildPrompt`) are
reachable without widening their access in production code. Anything that must stay sealed can get a
small internal test seam.

### Initial test files

- `SurfacerTests.swift`
  - `tokens` drops stopwords/short tokens, lowercases, splits on non-alphanumerics.
  - `rank` requires an entity/title anchor (pure content overlap doesn't surface).
  - Entity phrase match ("Q3 launch") vs single-token match; category weighting orders results;
    importance nudge breaks ties.
- `ConsolidatorParseTests.swift`
  - `parseJSON` strips ```json fences, isolates the outer object amid stray prose, throws on junk.
  - `gate` payload parsing keeps valid indices, ignores out-of-range, always keeps `[IMPORTANT]`.
- `ConsolidatorMergeTests.swift`
  - exact-title update vs create; importance ratchets up (`max`); entities union+sort;
    `related` produces bidirectional links; `linkByEntity` links shared-entity memories; no
    self-links / dangling links.
- `DiarizerTests.swift`
  - cosine/centroid update math; two distinct synthetic fingerprints cluster apart, near-duplicates
    cluster together at the default threshold; centroid is the running mean.
- `SpokenSanitizeTests.swift`
  - `AssistantRunner.spoken(from:)` strips markdown links/URLs/bullets/"Sources:".
  - `textDelta` extracts text from a real `stream_event` line and returns nil for other lines.

### CI

Add a step to `.github/workflows/ci.yml`: `swift test` after the build check (macOS runner already
present). Keep it fast — these are all in-memory unit tests.

## Files touched

- `Package.swift` — add `.testTarget`.
- **New:** `Tests/NemoTests/*.swift` (the files above).
- `.github/workflows/ci.yml` — add `swift test`.
- Possibly tiny internal seams in `Consolidator` if `@testable` alone is insufficient (it usually
  isn't for `private static`, so prefer `@testable`).

## Edge cases / constraints

- **No audio/UI/network in tests.** Anything touching `AVAudioEngine`, `NLEmbedding` availability,
  or the Claude CLI must be behind a protocol/seam or simply not unit-tested here. Keep these tests
  hermetic and sub-second.
- `NLEmbedding` (plan 01) tests should assert behaviour *given* a stubbed cosine, not the real
  model (which may be unavailable on CI runners).

## Risks / open questions

- `@testable import` of an `executableTarget`: confirm SwiftPM allows it (it does for executables
  on recent toolchains). If a snag appears, factor the pure logic into a `Nemo` *library* target
  that the executable and tests both depend on — a clean refactor worth doing anyway.

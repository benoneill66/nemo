# Nemo — Improvement Plans

This directory holds implementer-ready specs for the next wave of work on Nemo. Each
plan is self-contained: goal, why, current state (grounded in the real code), design with
code sketches, files touched, data/config changes, edge cases, testing, and risks.

Nemo's guiding constraints — keep every plan inside these:

- **Privacy-first.** Raw audio never leaves the Mac. On-device features stay on-device.
  The only network egress is the Claude CLI subprocess, already user-authenticated.
- **Zero third-party SwiftPM dependencies.** Apple frameworks only. (SQLite via the
  system `libsqlite3` is allowed — it ships with macOS — but a Swift package wrapper is not
  without discussion.)
- **Two-speed architecture.** Cheap/instant work runs on-device and inline (diarization,
  surfacing). Expensive work goes through the Claude CLI and is batched/gated.

## The plans

| # | Plan | Theme | Effort | Depends on |
|---|------|-------|--------|------------|
| 01 | [Semantic surfacing via `NLEmbedding`](01-semantic-surfacing.md) | Smarter memory | M | — |
| 02 | [Memory decay & reinforcement](02-memory-reinforcement.md) | Smarter memory | S | — |
| 03 | [Dedup / merge pass](03-dedup-merge.md) | Smarter memory | M | — |
| 04 | [Contradiction detection & supersede](04-contradiction-detection.md) | Smarter memory | M | 03 |
| 05 | [Memory editing, pin & provenance](05-memory-editing-provenance.md) | Trust & control | M | — |
| 06 | [Privacy controls (pause, exclusions, redaction)](06-privacy-controls.md) | Trust & control | M | — |
| 07 | [Test target](07-test-suite.md) | Reliability | S | — |
| 08 | [Claude CLI resilience & retry queue](08-cli-resilience.md) | Reliability | M | — |
| 09 | [LLM usage & cost visibility](09-usage-visibility.md) | Reliability | S | 08 |
| 10 | [SQLite data layer](10-sqlite-data-layer.md) | Scale | L | 05 |
| 11 | [Retrieval-augmented "Hey Nemo"](11-rag-hey-nemo.md) | Reach | M | 01 |
| 12 | [Local MCP memory server](12-mcp-server.md) | Reach | M | — |
| 13 | [Calendar / Reminders export](13-calendar-export.md) | Reach | S | — |

Effort: **S** ≈ ≤1 day, **M** ≈ 2–4 days, **L** ≈ 1–2 weeks.

## Recommended sequencing

The dependency-respecting order that front-loads user-visible value:

1. **07 Test target** first — cheap insurance before touching `Surfacer` / `Consolidator`.
2. **01 Semantic surfacing** — biggest single upgrade to the core experience; introduces
   the on-device embedding index that **11 RAG Hey Nemo** then reuses.
3. **05 Memory editing & provenance** — essential trust feature for an always-on recorder.
4. **08 CLI resilience** → **09 Usage visibility** — harden the one external dependency,
   then surface what it's spending.
5. **02 / 03 / 04** memory-hygiene trio — keep the graph clean as it grows.
6. **11 RAG Hey Nemo** and **12 MCP server** — turn the memory graph into a product surface.
7. **06 Privacy controls** and **13 Calendar export** — slot in anywhere; both standalone.
8. **10 SQLite** — defer until memory count or save latency actually hurts; it's the most
   invasive change and benefits from 05's editing API landing first.

## Shared building blocks introduced

Several plans lean on the same new pieces — build them once, in the plan that introduces them:

- **`EmbeddingIndex`** (plan 01): on-device `NLEmbedding` vectors per memory, cosine search.
  Reused by 11.
- **Memory provenance (`sourceSegmentIds`)** (plan 05): link memories back to the transcript
  segments they came from. Reused by 04 (to cite contradictions) and 11 (to ground answers).
- **`AssistantRunner` metering hook** (plan 08): a single choke point that records every CLI
  call's outcome + token usage. Reused by 09.

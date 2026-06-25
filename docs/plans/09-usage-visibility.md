# Plan 09 — LLM usage & cost visibility

**Theme:** Reliability · **Effort:** S · **Depends on:** 08 (metering choke point)

## Goal

Show the user what Nemo's background LLM activity actually costs: calls made, tokens used,
estimated spend, and what the relevance gate dropped — so they can tune thresholds with evidence
instead of guessing.

## Why

Consolidation, gating, briefing, import, and spoken answers all spend tokens silently. A
privacy/cost-conscious user (the target audience for a local-first tool) currently has no idea
whether Nemo is making 5 calls a day or 500, or whether the gate is earning its keep. Visibility
builds trust and makes the config knobs (`consolidateMinutes`, `relevanceGate`, models)
actionable.

## Current state

- Plan 08 introduces a single metering wrapper around every CLI call recording
  `{feature, model, startedAt, duration, outcome, usage}`.
- Gate already reports drops in `statusText` ("Nothing to remember (N dropped)",
  AppState.swift:306) but nothing aggregates it.
- No persistence of usage, no UI.

## Design

### 1. Usage log

`UsageLog` — append-only ring of recent events, persisted via `Store` to `usage.json`:

```swift
struct UsageEvent: Codable {
    var feature: String      // "consolidate" | "gate" | "brief" | "import" | "answer"
    var model: String
    var at: Date
    var durationMs: Int
    var inputTokens: Int?    // from stream-json result event when available
    var outputTokens: Int?
    var outcome: String      // "ok" | "rate_limited" | "failed" | "timeout"
    var droppedSegments: Int?   // gate only
}
```

Cap to the last N (e.g. 1000) events or 30 days. The metering wrapper (plan 08) appends here.

### 2. Token capture

- For `stream-json` calls (spoken answers, plan 08 may switch consolidation to stream too), parse
  the final `result`/`message_delta` usage event for input/output tokens (add a small parser
  beside `textDelta` in Assistants.swift).
- For `text`-output calls, tokens may be unavailable — record calls/durations and estimate tokens
  from character counts as a fallback (clearly labelled "estimated").

### 3. Cost estimation

A tiny static price table keyed by model id (per-MTok input/output), with the current Claude model
ids already used in config (`claude-sonnet-4-6`, `claude-haiku-4-5`). Cost =
`in/1e6*inPrice + out/1e6*outPrice`. Keep the table in one constant, easy to update; show "est."
to set expectations. (Note: CLI usage may be covered by a Claude subscription rather than billed
per-token — present this as "usage", and cost as an *estimate* of equivalent API spend, with a note.)

### 4. UI — "Activity" view

A small pane or a section in an existing one:
- Today / 7-day rollup: calls by feature, total tokens, est. cost, gate drop rate
  ("gate dropped 62% of segments — saving ~X").
- A sparkline of calls/day.
- Recent events list with outcome badges (ties into plan 08's health states).

## Files touched

- **New:** `Sources/Nemo/UsageLog.swift` (model + rollups), `Pricing.swift` (table + estimate).
- `Sources/Nemo/Assistants.swift` — emit `UsageEvent` from the metering wrapper; parse usage from
  stream-json.
- `Sources/Nemo/Store.swift` — `loadUsage()` / `saveUsage()`.
- `Sources/Nemo/AppState.swift` — own `UsageLog`, expose rollups; record gate drops.
- `Sources/Nemo/Panes.swift` / `RootView.swift` — Activity view.
- `Sources/Nemo/Config.swift` — `usageTrackingEnabled` (default true), `usageRetentionDays`.

## Edge cases

- **Tokens unavailable** (text output): label values "est." and base on char heuristics; never
  present an estimate as exact.
- **Privacy:** the usage log stores *metadata only* — feature, model, counts, timing. Never prompt
  or response text. State this in the README.
- **Write volume:** append + periodic flush; don't fsync per call (reuse `Store`'s async atomic
  write, batch appends).

## Testing (see plan 07)

- Unit: rollup math (today vs 7-day buckets; gate drop-rate %).
- Unit: cost estimate for a known token count + model matches the price table.
- Unit: stream-json usage parser extracts input/output tokens from a sample result line.

## Risks / open questions

- Price table drift — keep it in one obvious constant with a "last updated" comment; it's an
  estimate, so minor drift is acceptable.
- If CLI auth is subscription-based, "cost" may mislead; lead the UI with **usage** (calls/tokens)
  and treat cost as a secondary, clearly-estimated figure.

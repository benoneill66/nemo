# Plan 08 — Claude CLI resilience & retry queue

**Theme:** Reliability · **Effort:** M · **Depends on:** — · **Unblocks:** 09

## Goal

Make the one hard external dependency — the `claude` CLI subprocess — fail gracefully and
recover automatically: clear UI state when the CLI is missing/logged-out/rate-limited, and a queue
that retries consolidation work instead of dropping it.

## Why

Every durable feature (consolidation, gate, briefing, import, spoken answers) routes through
`AssistantRunner` (Assistants.swift). Today failures surface as a one-line `statusText` and the
pending work's fate varies: a failed consolidation leaves segments unconsolidated (OK, retried
later) but a failed gate/briefing just logs and moves on. There's no detection of *why* it failed
(not installed vs not logged in vs rate-limited vs timeout), so the user can't act, and transient
failures aren't retried with backoff.

## Current state

- `claudeOneShot` (Assistants.swift:78) runs the CLI, throws `mkErr` on empty output / nonzero
  exit; `resolveBinary` (238) probes a fixed candidate list and returns nil if absent.
- `runConsolidation` catches and sets `statusText = "Consolidation failed: …"` (AppState.swift:333).
- No classification of error type; no retry/backoff; no health surface.

## Design

### 1. Typed errors

Replace the single `mkErr` domain error with a classified enum so callers and UI can branch:

```swift
enum AssistantError: Error {
    case notInstalled            // resolveBinary == nil
    case notAuthenticated        // stderr matches login/auth patterns
    case rateLimited(retryAfter: TimeInterval?)   // stderr/exit indicates 429/usage limit
    case timedOut
    case emptyOutput
    case failed(status: Int32, stderr: String)
}
```

Classify in `claudeOneShot`/`exec` by inspecting exit status + stderr substrings (the CLI prints
recognisable messages for "not logged in" and usage limits). Keep a permissive default
(`.failed`).

### 2. Health probe + status

- `AssistantRunner.health() async -> Health` — fast check: binary resolves? a `--version`
  succeeds? Cache the result briefly.
- `AppState.assistantHealth` published property; a persistent banner/menu-bar indicator when
  `notInstalled` or `notAuthenticated`, with a one-line fix ("Run `claude login` in Terminal").
  This is far better than a transient `statusText`.

### 3. Retry queue with backoff

A small `ConsolidationQueue` so transient failures don't lose work:
- Consolidation is *already* idempotent-ish (segments stay `!consolidated` on failure and get
  retried at the next trigger). Formalise it: on `.rateLimited`/`.timedOut`/`.failed`, schedule a
  retry with exponential backoff (e.g. 30s → 2m → 8m, capped), respecting `retryAfter`.
- Pause the consolidate timer while `notInstalled`/`notAuthenticated` (no point hammering); resume
  on next successful `health()`.
- Briefing and import: same backoff treatment; surface "will retry" rather than silent failure.

### 4. Single choke point for metering (sets up plan 09)

Route **all** CLI invocations through one wrapper that records `{feature, model, startedAt,
duration, outcome, usage}` — this is where plan 09 reads usage. `claudeOneShot` and `run` both call
it. (Token usage is available from `--output-format stream-json` result events; for `text` output
we at least record calls + durations + outcomes.)

## Files touched

- `Sources/Nemo/Assistants.swift` — `AssistantError`, classification, `health()`, metering wrapper.
- `Sources/Nemo/AppState.swift` — `assistantHealth`, retry/backoff scheduling, pause timer on
  hard-down states.
- `Sources/Nemo/RootView.swift` / menu bar — health banner + remediation hint.
- `Sources/Nemo/Config.swift` — `retryBackoffSeconds`, `maxRetries`.

## Edge cases

- **Logged out mid-session:** detected on next call → banner + queue holds work → auto-clears and
  drains when login restored (next `health()` passes).
- **Rate limit with `retry-after`:** honour it; don't back off shorter than the server asks.
- **Timeout vs slow success:** current 240s timeout for consolidation is generous; keep but make it
  a config knob; on timeout, retry rather than mark consolidated.
- **Partial stream then failure** (spoken answers): keep whatever text streamed (existing behaviour
  in `runClaude`), classify the failure for the banner only.

## Testing (see plan 07)

- Unit: error classification from representative stderr strings (not-logged-in, usage-limit,
  generic).
- Unit: backoff schedule progression and cap; `retryAfter` overrides computed backoff.
- Manual: temporarily rename the `claude` binary → expect `notInstalled` banner, no crash, work
  queued; restore → queue drains.

## Risks / open questions

- The CLI's stderr wording can change between versions; keep classification patterns in one place
  and default safely to `.failed` (which still retries) so a wording change degrades to "generic
  retry", never a crash.

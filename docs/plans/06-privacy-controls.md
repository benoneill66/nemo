# Plan 06 — Privacy controls (pause, exclusions, redaction)

**Theme:** Trust & control · **Effort:** M · **Depends on:** —

## Goal

Give the user fast, trustworthy control over *when* and *what* Nemo captures: a one-tap timed
pause, automatic pausing in sensitive contexts, and an optional redaction pass that strips secrets
before anything is persisted or sent to the LLM.

## Why

An always-listening assistant lives or dies on trust. Today the only control is the global
listening toggle (`toggleListening`, AppState.swift:82) — all-or-nothing, with no "give me 30
private minutes", no exclusions, and no protection against a spoken password ending up in
`memories.json` or in a Claude CLI prompt. These controls make the always-on default defensible.

## Current state

- `start()`/`stop()` are the only gating (AppState.swift:84–98).
- Every finalized segment is stored verbatim (`ingest`, AppState.swift:135) and later sent to the
  Claude CLI for consolidation/gating.
- No concept of pause-with-resume, no exclusion list, no redaction.

## Design

### 1. Timed pause ("private mode")

- `func pause(for seconds: TimeInterval)` — stops the engine, sets `pausedUntil`, schedules an
  auto-resume timer; UI shows a countdown and a "resume now" button.
- Menu-bar quick actions: Pause 15 min / 1 hour / until I resume.
- Distinct from `stop()` (which is "off"): pause auto-resumes and is visually a temporary state.

### 2. Context-based auto-pause

Pause capture when a sensitive context is detected, resume when it clears:
- **Frontmost-app exclusion:** poll `NSWorkspace.shared.frontmostApplication` (or observe
  `didActivateApplicationNotification`); if the bundle id is in `excludedApps`
  (e.g. password managers, banking apps), auto-pause. No new permission needed.
- **Spoken pause/resume phrases:** add to the existing phrase-detection in `ingest`
  (alongside `meetingStartPhrases`, AppState.swift:127) — e.g. "pause listening" / "stop
  recording" → pause; "resume listening" → resume. These segments themselves are dropped.
- (Optional, later) a configurable do-not-disturb schedule (quiet hours).

### 3. Redaction pass (before persist + before LLM)

A pure on-device scrub applied in `ingest` *before* `segments.append` and again as a safety net in
`Consolidator.buildPrompt`:
- Detect-and-mask patterns: long digit runs (card/account numbers), things spoken right after a
  trigger word ("my password is …", "the code is …", SSN-shaped, API-key-shaped tokens).
- Replace with `‹redacted›` rather than dropping, so context stays readable.
- Implement as `Redactor.scrub(_ text:) -> (clean: String, didRedact: Bool)`; mark redacted
  segments so the UI can show a shield glyph and the user knows it worked.
- Off by default? No — recommend **on by default** for the obvious high-risk patterns (cards,
  "password is"), with config to tune. Conservative patterns keep false positives low.

## Files touched

- **New:** `Sources/Nemo/Redactor.swift` (pure, testable).
- `Sources/Nemo/AppState.swift` — `pause(for:)`, `pausedUntil`, resume timer, spoken
  pause/resume phrases, redaction call in `ingest`, frontmost-app observation.
- `Sources/Nemo/Consolidator.swift` — defensive `Redactor.scrub` in `buildPrompt`.
- `Sources/Nemo/RootView.swift` / menu bar — pause quick actions + countdown UI.
- `Sources/Nemo/Config.swift` — `excludedApps: [String]`, `redactionEnabled` (default true),
  `pausePhrases` / `resumePhrases`, `redactionPatterns` override.

## Edge cases

- **Pause during a meeting:** allowed; the meeting session stays open, capture just stops; resume
  continues into the same session if still open.
- **App focus flapping:** debounce frontmost-app changes (e.g. 2s) so a quick alt-tab doesn't
  thrash pause/resume.
- **Redaction false positives:** masking is reversible only by the user re-speaking; keep patterns
  tight and surface what was redacted so they can adjust config. Never log the pre-redaction text.
- **Spoken pause phrase mid-sentence:** drop the whole segment containing the phrase to avoid
  capturing the sensitive lead-in.

## Testing (see plan 07)

- Unit: `Redactor.scrub` masks card numbers and "password is X" while leaving ordinary speech
  intact; idempotent.
- Unit: spoken "pause listening" transitions state and the triggering segment is not stored.
- Manual: add a password-manager bundle id to `excludedApps`, focus it, confirm auto-pause and
  the countdown/indicator; confirm resume on blur.

## Risks / open questions

- Frontmost-app detection requires the app to be running normally (it is, as a menu-bar app); no
  extra entitlement, but verify under App Sandbox if that's ever enabled.
- Redaction can never be perfect; position it as "reduces obvious leaks", not a guarantee, in
  copy. The strongest control remains the timed pause.

# Changelog

All notable changes to Nemo are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Gmail context import.** Link a Gmail account (read-only) from the **Import** tab and pull
  recent mail straight into memory. Auth uses Google's OAuth **loopback** flow — Nemo opens
  your browser, you approve, and a refresh token is stored locally (`0600`); no password and no
  embedded webview. If the `gog` CLI is set up, Nemo **reuses its stored OAuth client**, so no
  Google Cloud registration is needed — just click Connect. Pulled mail runs through the same
  import pipeline as file/assistant sources, so inbox commitments, people, and decisions become
  categorized, linked memories. Optionally override with a `"gmail"` OAuth client block (or
  `GMAIL_CLIENT_ID` / `GMAIL_CLIENT_SECRET`) in `config.json`; bound what's pulled with
  `query` / `maxMessages`.

## [1.2.0] — 2026-06-26

### Added

- **Floating "listening" overlay bar.** A borderless, always-on-top HUD that follows you
  across Spaces and parks in the bottom-right corner whenever Nemo is open. It shows a live
  waveform driven by the mic level and expands on its own to reflect what Nemo is doing —
  saving to memory, importing, or surfacing a relevant memory. Tap to toggle listening,
  drag to reposition. Disable with `"overlay": false`.
- **Open the app from the overlay.** A window button on the overlay bar activates Nemo and
  reopens/raises the main window — so the app is reachable even when its window is closed.
- **Delete sessions.** Each session in the Sessions pane now has a delete button (with a
  confirmation) that removes the session and its captured transcript segments. Memories
  already distilled from the session are kept.

## [1.1.0] — 2026-06-25

A wave of intelligence, trust, and reach features — all on-device or through your own
Claude CLI, with no new third-party dependencies.

### Added

- **Speaker identification (diarization).** Tells apart distinct voices in the transcript
  using on-device acoustic fingerprints (mel-frequency cepstral coefficients + pitch),
  clustered online into "Speaker 1/2/…". Speakers are renameable, persist across launches
  (a returning voice re-matches its identity), label each transcript line in the Live and
  Sessions panes, and feed into how memories are attributed. Entirely local — only acoustic
  features are derived, no audio is stored or sent. Tune with `"diarization"` /
  `"speakerThreshold"`.
- **Semantic surfacing.** The live "Relevant now" engine now blends on-device sentence
  embeddings (`NLEmbedding`) with lexical matching, so memories surface on meaning, not just
  shared words. Still no LLM call — instant and free. Tune with `"semanticSurface"` /
  `"semanticWeight"` / `"semanticFloor"`.
- **Morning briefing.** On the first open each day, Nemo distills open action items,
  unanswered questions, recent decisions, and what your last sessions covered into a short
  spoken-style catch-up — a card on the Live tab (tap to hear it) and a menu-bar action.
  Generated once daily and cached. Tune with `"briefing"` / `"briefingSpeak"`.
- **Memory editing, pinning & provenance.** Edit a memory's title, content, or category
  inline; pin importance so automation won't override it; and tap any memory to see the exact
  transcript segments it came from ("why is this here?"). Edits are tracked in a per-memory
  history.
- **Memory reinforcement & decay.** Memories that keep coming up are reinforced; stale ones
  decay over a configurable half-life, so the graph reflects what's currently live. Tune with
  `"reinforcement"` / `"decayHalfLifeDays"`.
- **Dedupe pass.** Periodically merges near-duplicate memories (cosine similarity over the
  embedding index) to keep the graph clean as it grows. Tune with `"dedupe"` /
  `"dedupeEveryNNew"` / `"dedupeCosine"`.
- **Contradiction detection & supersede.** New facts that conflict with old ones mark the
  stale memory as superseded (archived, restorable) rather than silently coexisting. Tune
  with `"contradictionDetection"`.
- **Privacy controls.** A one-tap timed private-mode pause (15 min / 1 hour / until resumed)
  from the menu bar and by voice, automatic pausing when an excluded app is frontmost, and an
  optional redaction pass that strips secrets before anything is persisted or sent to the LLM.
  Tune with `"redaction"` / `"excludedApps"` / `"pausePhrases"` / `"resumePhrases"`.
- **Retrieval-augmented "Hey Nemo".** Spoken questions are now grounded in the most relevant
  memories retrieved from your graph before being answered, with provenance. Tune with
  `"memoryGroundedAnswers"` / `"answerMemoryK"`.
- **Apple Reminders export.** Action items can flow into Apple Reminders via EventKit —
  manually from a memory's detail view, or automatically. On-device, no network. Tune with
  `"calendarExport"` / `"autoExportTasks"` / `"remindersListName"`.
- **Local MCP memory server (`NemoMCP`).** A local [MCP](https://modelcontextprotocol.io)
  server exposing your memory graph (read-only) to clients like Claude Code and Claude
  Desktop — `search_memories`, `list_recent`, `list_action_items`, `search_transcript`. No
  network listener, never touches audio. Tune with `"mcp"` / `"mcpAllowWrite"`.
- **LLM usage & cost visibility (Activity tab).** A new Activity pane meters every background
  Claude call — duration, token counts, outcome, by-feature breakdown, and how much the
  relevance gate is saving. Metadata only; no prompt/response text. Tune with
  `"usageTracking"` / `"usageRetentionDays"`.
- **Optional SQLite storage backend.** Set `"storageBackend": "sqlite"` to store memories and
  segments in an indexed `nemo.db` with full-text transcript search; JSON is migrated in once
  and kept mirrored as a backup, so you can switch back any time. Defaults to JSON.

### Changed

- **Claude CLI resilience.** The CLI is now a single metered choke point with typed errors, an
  up-front health probe with an in-app banner when the CLI is unavailable, and automatic
  retry with backoff for transient failures. Tune with `"maxRetries"` / `"retryBackoffSeconds"`.

## [1.0.0] — 2026-06-25

First public release.

### Added

- **Always-listening, on-device transcription.** Continuous speech recognition using
  Apple's `SpeechAnalyzer`/`SpeechTranscriber` enhanced-dictation engine on macOS 26+,
  with an `SFSpeechRecognizer` fallback on older systems. Raw audio never leaves the Mac.
- **Memory engine.** Periodically distills recent transcript into categorized,
  interconnected memories via the Claude CLI (no API keys) — People, Projects, Decisions,
  Action Items, Preferences, Facts, Meetings, Ideas, Open Questions.
- **Meeting capture.** Start/stop sessions by voice or button; each meeting gets a
  Claude-written summary folded into memory.
- **Keyword marking.** Say "important", "remember this", "action item", etc. to star a
  moment and raise its importance during consolidation.
- **Context import.** Auto-discovers existing Claude file memories and parses them
  directly (no LLM); distills freeform sources (`CLAUDE.md`, ChatGPT exports) in chunks.
- **Spoken answers.** Say "Hey Nemo, …" to route a question to Claude and hear the reply.
- **Glassmorphic SwiftUI app** with a menu-bar control: Live, Memory, Sessions, and
  Import panes.
- **Packaging.** `build.sh`, `install.sh`, and `package.sh` for a signed `.app` and a
  drag-to-install `.dmg`.

[Unreleased]: https://github.com/benoneill66/nemo/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/benoneill66/nemo/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/benoneill66/nemo/releases/tag/v1.0.0

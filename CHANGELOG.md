# Changelog

All notable changes to Nemo are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Speaker identification (diarization).** Tells apart distinct voices in the transcript
  using on-device acoustic fingerprints (mel-frequency cepstral coefficients + pitch),
  clustered online into "Speaker 1/2/…". Speakers are renameable, persist across launches
  (a returning voice re-matches its identity), label each transcript line in the Live and
  Sessions panes, and feed into how memories are attributed. Entirely local — only acoustic
  features are derived, no audio is stored or sent. Tune with `"diarization"` /
  `"speakerThreshold"` in `config.json`.

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

[Unreleased]: https://github.com/benoneill66/nemo/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/benoneill66/nemo/releases/tag/v1.0.0

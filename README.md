<div align="center">

# Nemo

**An always-listening, on-device memory assistant for macOS.**

[![CI](https://github.com/benoneill66/nemo/actions/workflows/ci.yml/badge.svg)](https://github.com/benoneill66/nemo/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/benoneill66/nemo?sort=semver)](https://github.com/benoneill66/nemo/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)

[**Landing page**](https://benoneill66.github.io/nemo/) · [**Download**](https://github.com/benoneill66/nemo/releases/latest) · [**Contributing**](CONTRIBUTING.md) · [**Changelog**](CHANGELOG.md)

</div>

An **always-listening** macOS assistant with a native **glassmorphic** UI. It transcribes
everything it hears **on-device**, then periodically distills the transcript into a rich,
**interconnected, categorized memory** of your life and work — meetings, decisions, people,
tasks, ideas. You can seed it with what other AI assistants (e.g. Claude) already know about
you, and flag important moments just by saying a keyword.

It uses the **Claude CLI** to build memory (reusing your existing login — **no API keys**),
and Apple's Speech framework for transcription, so raw audio never leaves your Mac.

## What it does

- **Transcribes everything** — continuous on-device speech recognition. On **macOS 26+** it
  uses Apple's new `SpeechAnalyzer`/`SpeechTranscriber` — the same enhanced-dictation engine
  the system uses — for higher accuracy, automatic punctuation, and true long-form capture.
  Older systems fall back to `SFSpeechRecognizer`. The active engine is shown in the sidebar.
- **Builds memory** — every few minutes (and when a meeting ends) recent transcript first
  passes a **cheap relevance gate** (a fast Haiku model) that decides which lines hold anything
  worth keeping; pure chit-chat is dropped and never reaches the expensive model. Whatever
  survives goes to Claude, which distills durable notes, **categorizes** them (People, Projects,
  Decisions, Action Items, Preferences, Facts, Meetings, Ideas, Open Questions…), and **links**
  related memories into a graph (by reference and by shared entities). Irrelevant raw segments
  are discarded immediately, and consolidated ones are pruned after a retention window, so the
  transcript stays small (your marked moments and meeting transcripts are always kept).
- **Surfaces what's relevant, as you speak** — the point of a memory is having it at the
  right moment. An on-device relevance engine watches the rolling transcript and, when a
  person, project, or topic comes up, instantly surfaces the memories that matter — the open
  action item, the decision you made last time, that person's preference — in a **Relevant
  now** strip on the Live tab. It blends lexical matching with on-device sentence embeddings
  (`NLEmbedding`), so it matches on **meaning**, not just shared words. No LLM call, so it's
  instant and free; it's weighted toward actionable categories and fades out as the
  conversation moves on.
- **Morning briefing** — when you open Nemo each day it distills your memory into a short,
  spoken-style catch-up: what's outstanding (open action items, unanswered questions), recent
  decisions, and what your last sessions were about. It shows as a card on the Live tab (tap
  to hear it read aloud) and a **Morning Briefing** action in the menu bar. Generated once per
  day and cached, so reopening is instant.
- **Tells speakers apart** — distinguishes distinct voices in the transcript with on-device
  acoustic fingerprints (mel-frequency cepstral coefficients + pitch), clustered into
  **Speaker 1/2/…** with no setup and no idea up front how many people are talking. Tap a
  speaker to give them a real name; the name flows through the transcript, the session view,
  and how Claude attributes facts and decisions during consolidation. Voices persist across
  launches, so a returning speaker keeps their identity. Like everything else, it's local —
  only acoustic features are derived, never stored or sent.
- **Captures meetings** — start a session by voice ("start meeting") or a button; everything
  said is grouped, and when it ends Claude writes a summary and folds it into memory.
- **Mark by keyword** — say "important", "remember this", "action item", "note to self", etc.
  and that moment is starred and pushed to high importance during consolidation.
- **Imports existing context** — auto-discovers Claude's file memories so it starts out
  already knowing you. Claude's memories are already structured (one fact per file, with
  categories and `[[links]]`), so they're **parsed directly — instantly, no LLM** — preserving
  their categories and interconnections. Freeform sources (a prose `CLAUDE.md`, a ChatGPT
  export) are distilled by Claude in large chunks run concurrently.
- **Keeps the graph clean as it grows** — memories you keep touching are **reinforced** while
  stale ones **decay** over a configurable half-life, so what's live floats to the top. A
  periodic **dedupe** pass merges near-duplicates (by embedding similarity), and
  **contradiction detection** marks an outdated fact as *superseded* — archived and restorable,
  not silently coexisting with its replacement — when a newer one conflicts with it.
- **Edit, pin & trace any memory** — fix a title, content, or category inline; **pin**
  importance so automation won't override it; and tap a memory to see the exact transcript
  segments it came from ("why is this here?"). Every edit is kept in a per-memory history.
- **Private by command** — a one-tap **timed pause** (15 min / 1 hour / until you resume) from
  the menu bar or by voice ("pause listening"), automatic pausing when an **excluded app** is
  frontmost, and an optional **redaction** pass that strips secrets before anything is stored
  or sent to Claude.
- **Pushes tasks to Reminders** — action items can flow into **Apple Reminders** via EventKit,
  from a memory's detail view or automatically, so "I'll send the deck Friday" becomes a real
  reminder. On-device, no network.
- **Shows what it's spending** — an **Activity** tab meters every background Claude call
  (duration, tokens, outcome, by-feature breakdown, and how much the relevance gate is saving).
  Metadata only — no prompt or response text is recorded.
- **Works from your other AI tools** — a bundled local **MCP** server exposes your memory graph
  (read-only) to clients like Claude Code and Claude Desktop. See [below](#use-your-memory-from-other-ai-tools-mcp).
- **Resilient by default** — the Claude CLI is wrapped in typed errors, an up-front health
  probe with an in-app banner if it's unavailable, and automatic retry with backoff for
  transient failures.
- **Answers out loud (bonus)** — say "Hey Nemo, …" and it routes the question to Claude and
  speaks the reply, **grounded in the most relevant memories** from your graph, while still
  transcribing in the background.

## How it works

```
mic ──▶ AVAudioEngine ──▶ SFSpeechRecognizer (on-device, rolling windows)
                               │
                  time-stamped transcript segments
                               │
        ┌──────────────────────┼───────────────────────────┐
   keyword marking      meeting sessions            "hey nemo …"
   (important/…)        (start/end → summary)        → Claude → spoken reply
                               │
              every ~5 min / on meeting end          per finalized segment
                               │                              │
                    Claude CLI (memory engine)      on-device relevance engine
                               │                              │
        categorized, interconnected memories  ──┬──▶  glassmorphic UI + JSON on disk
                                                 └──▶  "Relevant now" surfacing (instant)
```

Nothing but distilled text is ever sent anywhere, and only to your own Claude CLI. Raw audio
is processed on-device and never uploaded.

## Install

```bash
./install.sh          # builds Nemo and copies it to /Applications, then launches it
```

On first launch **allow** the Microphone and Speech-Recognition prompts, then press
**Start Listening**. Because the bundle is built on your own Mac it isn't quarantined, so it
opens with no Gatekeeper warning. To launch at login: System Settings → General → Login
Items → **+** → `/Applications/Nemo.app`.

### Build only (no install)

```bash
./build.sh            # → ./Nemo.app   (run with: open Nemo.app)
```

`build.sh` compiles a release binary, assembles `Nemo.app` with its icon (a real bundle is
required so macOS shows the TCC prompts), and signs it with the right entitlements. Ad-hoc by
default; set `CODESIGN_ID="Developer ID Application: …"` for a hardened-runtime, notarizable
build.

### Share with others

```bash
./package.sh          # → ./Nemo.dmg   (drag Nemo into Applications)
```

Produces a drag-to-install disk image. Without a Developer ID signature, the first launch on
*another* Mac needs a right-click → **Open** (or `xattr -dr com.apple.quarantine
/Applications/Nemo.app`). The app icon is regenerated from `make-icon.swift` via
`./make-icns.sh` if you want to tweak the artwork.

## The app

A native SwiftUI window (plus a menu-bar control) with a frosted, glassmorphic look:

- **Live** — what's being heard right now, the streaming transcript, the *Relevant now* strip,
  the daily briefing card, and a *Consolidate Now* button. Star any line to mark it important.
- **Memory** — the knowledge graph: filter by category, browse glass cards (title, notes,
  importance, entities, link count), and open one to *edit* it, *pin* its importance, see
  everything it's *connected to*, trace its source transcript, or push it to Reminders.
- **Sessions** — meetings and daily ambient capture, each with its summary and transcript.
- **Import** — discovered assistant memories to seed from, one click each.
- **Activity** — what Nemo's background AI is doing: per-call duration, tokens, outcome, a
  by-feature breakdown, and the relevance gate's savings — metadata only.

The menu-bar control adds a **Pause** menu (timed private mode) and a **Morning Briefing**
action alongside the listening toggle.

## Configure (optional)

No API keys required — memory is built with your Claude CLI login. Config lives at
`~/.config/nemo/config.json`; every field is optional with sensible defaults.

```json
{
  "engine": "auto",
  "locale": "en-GB",
  "consolidateMinutes": 5,
  "consolidateMinSegments": 6,
  "memoryModel": "claude-sonnet-4-6",
  "gateModel": "claude-haiku-4-5",
  "relevanceGate": true,
  "diarization": true,
  "speakerThreshold": 1.5,
  "transcriptRetentionDays": 7,
  "markers": ["important", "remember this", "action item", "note to self", "follow up"],
  "meetingStart": ["start meeting", "begin meeting"],
  "meetingStop": ["end meeting", "stop meeting"],
  "wakeAnswer": true,
  "wakeWords": ["nemo", "nimo", "neemo"],
  "importPaths": ["~/Downloads/chatgpt-export"],
  "voice": "Zoe (Premium)",
  "rate": 0.5,

  "surface": true,
  "semanticSurface": true,
  "briefing": true,
  "briefingSpeak": false,
  "reinforcement": true,
  "decayHalfLifeDays": 30,
  "dedupe": true,
  "contradictionDetection": true,
  "redaction": true,
  "excludedApps": ["1Password", "Messages"],
  "pausePhrases": ["pause listening", "stop recording"],
  "memoryGroundedAnswers": true,
  "calendarExport": false,
  "autoExportTasks": false,
  "remindersListName": "Nemo",
  "usageTracking": true,
  "mcp": true,
  "storageBackend": "json"
}
```

- `engine` — transcription backend: `auto` (enhanced dictation on macOS 26+, else standard),
  `dictation`, or `legacy` to force the older recognizer.
- `locale` — transcription language, e.g. `en-GB`, `en-US`, `fr-FR`. Defaults to the system
  locale; the on-device model downloads automatically the first time a locale is used.
- `consolidateMinutes` / `consolidateMinSegments` — how often memory is rebuilt (by time, or
  once this many new segments pile up).
- `memoryModel` — Claude model used for consolidation & import.
- `gateModel` — cheap/fast model for the pre-consolidation relevance gate (defaults to Haiku).
- `relevanceGate` — set `false` to consolidate every segment (skip the gate entirely).
- `diarization` — set `false` to turn off speaker identification (no voice fingerprinting).
- `speakerThreshold` — how readily two voices count as the same person. Higher merges speakers
  together; lower splits more eagerly. `~1.5` is a sensible middle — nudge down if one person is
  split into several, up if several people collapse into one.
- `transcriptRetentionDays` — days to keep consolidated raw segments before pruning (`0` keeps
  them forever). Marked moments and meeting transcripts are never auto-pruned.
- `markers` — spoken phrases that flag a moment as important.
- `meetingStart` / `meetingStop` — spoken phrases that open/close a meeting session.
- `wakeAnswer` — set `false` to disable the spoken "Hey Nemo, …" answer feature.
- `wakeWords` — wake words (without "hey") for the answer feature; add mishear variants.
- `importPaths` — extra files/dirs of existing assistant memory to offer in the Import tab.
- `voice` / `rate` — TTS voice and speed for spoken answers. Omit `voice` to auto-pick the
  best English voice installed. Download **Premium** voices in *System Settings →
  Accessibility → Spoken Content → System Voice → Manage Voices*.
- `surface` / `semanticSurface` — the live *Relevant now* engine, and whether it blends
  on-device embeddings (meaning) with lexical matching. Fine-tune with `surfaceWindowSeconds`,
  `surfaceTTLSeconds`, `surfaceMax`, `surfaceMinScore`, `semanticWeight`, `semanticFloor`.
- `briefing` / `briefingSpeak` — the once-a-day morning briefing, and whether it's read aloud
  automatically (off by default — it shows as a tap-to-hear card).
- `reinforcement` / `decayHalfLifeDays` — reinforce memories that recur and decay stale ones
  over this half-life (in days).
- `dedupe` / `contradictionDetection` — periodic merge of near-duplicate memories, and marking
  an outdated fact as superseded when a newer one conflicts. Fine-tune with `dedupeEveryNNew`,
  `dedupeCosine`.
- `redaction` — strip secrets before anything is persisted or sent to Claude.
- `excludedApps` — app names that auto-pause capture while they're frontmost.
- `pausePhrases` / `resumePhrases` — spoken phrases that enter/leave private-mode pause.
- `memoryGroundedAnswers` — ground "Hey Nemo" answers in retrieved memories (`answerMemoryK`
  sets how many).
- `calendarExport` / `autoExportTasks` / `remindersListName` — enable Apple Reminders export,
  whether action items export automatically, and which Reminders list to use.
- `usageTracking` — record per-call LLM metadata for the Activity tab (`usageRetentionDays`
  bounds how long it's kept). Resilience: `maxRetries`, `retryBackoffSeconds`.
- `mcp` / `mcpAllowWrite` — enable the local MCP server, and (off by default) allow it to write.
- `storageBackend` — `"json"` (default) or `"sqlite"` (indexed store with full-text transcript
  search; see [Where data lives](#where-data-lives)).

## Where data lives

Everything is plain JSON under `~/.config/nemo/data/`:

| File | Contents |
|------|----------|
| `transcript.json` | time-stamped transcript segments (with marks + session) |
| `memories.json` | the categorized, interconnected memory graph |
| `sessions.json` | ambient days and meetings, with summaries |
| `speakers.json` | learned voice fingerprints (acoustic features only) |
| `embeddings.json` | on-device semantic vectors per memory (cache; safe to delete) |
| `usage.json` | metered LLM activity — metadata only, no prompt/response text |
| `nemo.db` | SQLite store for memories + segments (only when `storageBackend: "sqlite"`) |

Delete a file to reset that part; the app rebuilds from there.

Storage defaults to JSON. Set `"storageBackend": "sqlite"` in `config.json` to use an indexed
SQLite store (with full-text transcript search) for memories and segments; JSON is migrated in
once and kept mirrored as a backup, so you can switch back any time.

## Use your memory from other AI tools (MCP)

Nemo ships a local [MCP](https://modelcontextprotocol.io) server, `NemoMCP`, that exposes your
memory graph (read-only) to MCP clients like Claude Code and Claude Desktop — so they can answer
from your real-world spoken context. It reads the same on-device JSON store; it opens no network
listener and never touches audio.

```sh
swift build -c release
claude mcp add nemo -- "$(pwd)/.build/release/NemoMCP"
```

Tools: `search_memories` (semantic + keyword), `list_recent`, `list_action_items`,
`search_transcript`. Read-only by default.

## Files

| File | Purpose |
|------|---------|
| `Sources/Nemo/NemoApp.swift` | `@main` SwiftUI app — window + menu-bar control |
| `Sources/Nemo/RootView.swift` | Glass sidebar, navigation, status |
| `Sources/Nemo/Panes.swift` | Live / Memory / Sessions / Import screens |
| `Sources/Nemo/Glass.swift` | Glassmorphic design system (vibrancy, cards, aurora) |
| `Sources/Nemo/AppState.swift` | Orchestrator: marking, sessions, consolidation, import |
| `Sources/Nemo/SpeechEngine.swift` | Shared backend protocol + engine selector |
| `Sources/Nemo/DictationEngine.swift` | macOS 26 `SpeechAnalyzer` enhanced dictation |
| `Sources/Nemo/TranscriptionEngine.swift` | `SFSpeechRecognizer` fallback transcription |
| `Sources/Nemo/Consolidator.swift` | Distills transcript → categorized, linked memory |
| `Sources/Nemo/Surfacer.swift` | On-device *Relevant now* engine (lexical + embeddings) |
| `Sources/Nemo/EmbeddingIndex.swift` | On-device `NLEmbedding` vectors + cosine search |
| `Sources/Nemo/Briefer.swift` | Builds the once-a-day morning briefing |
| `Sources/Nemo/Reinforcement.swift` | Memory reinforcement & time decay |
| `Sources/Nemo/Maintenance.swift` | Periodic dedupe + contradiction/supersede pass |
| `Sources/Nemo/MemoryQA.swift` | Retrieval-augmented answers for "Hey Nemo" |
| `Sources/Nemo/SpeakerDiarizer.swift` | On-device voice fingerprinting + speaker clustering |
| `Sources/Nemo/Redactor.swift` | Secret-stripping redaction before persist/send |
| `Sources/Nemo/ContextImporter.swift` | Seeds memory from other assistants' files |
| `Sources/Nemo/EventKitExporter.swift` | Exports action items to Apple Reminders |
| `Sources/Nemo/UsageLog.swift` | LLM call metering for the Activity tab |
| `Sources/Nemo/Pricing.swift` | Token-cost estimates for usage reporting |
| `Sources/Nemo/Models.swift` | Segment / Memory / Session / Speaker / Category models |
| `Sources/Nemo/Store.swift` | Persistence (JSON, with optional SQLite backend) |
| `Sources/Nemo/SQLite.swift` | Thin `libsqlite3` wrapper (system library) |
| `Sources/Nemo/SQLiteStore.swift` | Indexed SQLite store + full-text transcript search |
| `Sources/Nemo/Config.swift` | Typed view over `config.json` |
| `Sources/Nemo/Speaker.swift` | Text-to-speech for spoken answers |
| `Sources/Nemo/Assistants.swift` | Claude CLI plumbing + spoken-text sanitizing |
| `Sources/NemoMCP/main.swift` | Local MCP server exposing the memory graph (read-only) |
| `build.sh` | Compile → assemble `.app` (icon + entitlements) → sign |
| `install.sh` | Build → install to `/Applications` → launch |
| `package.sh` | Build → drag-to-install `Nemo.dmg` |
| `make-icon.swift` / `make-icns.sh` | Render the glassmorphic app icon → `AppIcon.icns` |
| `Nemo.entitlements` | Mic / network entitlements for signing |

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for setup and the
[Code of Conduct](CODE_OF_CONDUCT.md). For anything security- or privacy-related, see
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 Ben O'Neill. Raw audio never leaves your Mac; only distilled text
is sent, and only to your own Claude CLI.

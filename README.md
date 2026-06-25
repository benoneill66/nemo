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
- **Builds memory** — every few minutes (and when a meeting ends) it sends recent transcript
  to Claude, which distills durable notes, **categorizes** them (People, Projects, Decisions,
  Action Items, Preferences, Facts, Meetings, Ideas, Open Questions…), and **links** related
  memories into a graph (by reference and by shared entities).
- **Surfaces what's relevant, as you speak** — the point of a memory is having it at the
  right moment. An on-device relevance engine watches the rolling transcript and, when a
  person, project, or topic comes up, instantly surfaces the memories that matter — the open
  action item, the decision you made last time, that person's preference — in a **Relevant
  now** strip on the Live tab. No LLM call, so it's instant and free; it's weighted toward
  actionable categories and fades out as the conversation moves on.
- **Morning briefing** — when you open Nemo each day it distills your memory into a short,
  spoken-style catch-up: what's outstanding (open action items, unanswered questions), recent
  decisions, and what your last sessions were about. It shows as a card on the Live tab (tap
  to hear it read aloud) and a **Morning Briefing** action in the menu bar. Generated once per
  day and cached, so reopening is instant.
- **Captures meetings** — start a session by voice ("start meeting") or a button; everything
  said is grouped, and when it ends Claude writes a summary and folds it into memory.
- **Mark by keyword** — say "important", "remember this", "action item", "note to self", etc.
  and that moment is starred and pushed to high importance during consolidation.
- **Imports existing context** — auto-discovers Claude's file memories so it starts out
  already knowing you. Claude's memories are already structured (one fact per file, with
  categories and `[[links]]`), so they're **parsed directly — instantly, no LLM** — preserving
  their categories and interconnections. Freeform sources (a prose `CLAUDE.md`, a ChatGPT
  export) are distilled by Claude in large chunks run concurrently.
- **Answers out loud (bonus)** — say "Hey Nemo, …" and it routes the question to Claude and
  speaks the reply, while still transcribing in the background.

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

- **Live** — what's being heard right now, the streaming transcript, and a *Consolidate Now*
  button. Star any line to mark it important.
- **Memory** — the knowledge graph: filter by category, browse glass cards (title, notes,
  importance, entities, link count), and open one to see everything it's *connected to*.
- **Sessions** — meetings and daily ambient capture, each with its summary and transcript.
- **Import** — discovered assistant memories to seed from, one click each.

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
  "markers": ["important", "remember this", "action item", "note to self", "follow up"],
  "meetingStart": ["start meeting", "begin meeting"],
  "meetingStop": ["end meeting", "stop meeting"],
  "wakeAnswer": true,
  "wakeWords": ["nemo", "nimo", "neemo"],
  "importPaths": ["~/Downloads/chatgpt-export"],
  "voice": "Zoe (Premium)",
  "rate": 0.5
}
```

- `engine` — transcription backend: `auto` (enhanced dictation on macOS 26+, else standard),
  `dictation`, or `legacy` to force the older recognizer.
- `locale` — transcription language, e.g. `en-GB`, `en-US`, `fr-FR`. Defaults to the system
  locale; the on-device model downloads automatically the first time a locale is used.
- `consolidateMinutes` / `consolidateMinSegments` — how often memory is rebuilt (by time, or
  once this many new segments pile up).
- `memoryModel` — Claude model used for consolidation & import.
- `markers` — spoken phrases that flag a moment as important.
- `meetingStart` / `meetingStop` — spoken phrases that open/close a meeting session.
- `wakeAnswer` — set `false` to disable the spoken "Hey Nemo, …" answer feature.
- `wakeWords` — wake words (without "hey") for the answer feature; add mishear variants.
- `importPaths` — extra files/dirs of existing assistant memory to offer in the Import tab.
- `voice` / `rate` — TTS voice and speed for spoken answers. Omit `voice` to auto-pick the
  best English voice installed. Download **Premium** voices in *System Settings →
  Accessibility → Spoken Content → System Voice → Manage Voices*.

## Where data lives

Everything is plain JSON under `~/.config/nemo/data/`:

| File | Contents |
|------|----------|
| `transcript.json` | time-stamped transcript segments (with marks + session) |
| `memories.json` | the categorized, interconnected memory graph |
| `sessions.json` | ambient days and meetings, with summaries |

Delete a file to reset that part; the app rebuilds from there.

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
| `Sources/Nemo/ContextImporter.swift` | Seeds memory from other assistants' files |
| `Sources/Nemo/Models.swift` | Segment / Memory / Session / Category models |
| `Sources/Nemo/Store.swift` | JSON persistence |
| `Sources/Nemo/Config.swift` | Typed view over `config.json` |
| `Sources/Nemo/Speaker.swift` | Text-to-speech for spoken answers |
| `Sources/Nemo/Assistants.swift` | Claude CLI plumbing + spoken-text sanitizing |
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

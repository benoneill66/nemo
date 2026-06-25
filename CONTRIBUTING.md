# Contributing to Nemo

Thanks for your interest in improving Nemo! This is a small, focused macOS app and
contributions of all sizes are welcome — bug reports, docs, and code.

## Ground rules

- Be kind. See the [Code of Conduct](CODE_OF_CONDUCT.md).
- Keep the app **private by design**: raw audio stays on-device, and only distilled
  text is ever sent to your own Claude CLI. Any change that would weaken that promise
  needs a very good reason and a clear call-out in the PR.
- Match the surrounding style. The codebase favours small, single-purpose files and
  reads top-to-bottom.

## Getting set up

You'll need a Mac (Apple Silicon or Intel) and the Swift toolchain that ships with
Xcode or the Command Line Tools.

```bash
git clone https://github.com/benoneill66/nemo.git
cd nemo
swift build            # compile
./build.sh             # → ./Nemo.app  (a real bundle, needed for the mic/speech prompts)
open Nemo.app
```

For the full experience you also need the [Claude CLI](https://docs.claude.com/en/docs/claude-code)
installed and logged in — Nemo shells out to it to build memory (no API keys).

> **Note on macOS 26:** the enhanced-dictation engine uses Apple's `SpeechAnalyzer`,
> which requires the macOS 26 SDK to compile. On older systems the app falls back to
> `SFSpeechRecognizer` at runtime, but building still needs a recent Xcode.

## Making a change

1. Fork and create a branch: `git checkout -b my-change`.
2. Make your change. Keep commits focused and the diff readable.
3. Make sure it still builds cleanly: `swift build -c release`.
4. Run the app and sanity-check the area you touched.
5. Open a pull request describing **what** changed and **why**. Link any related issue.

## Reporting bugs & ideas

Use the [issue templates](https://github.com/benoneill66/nemo/issues/new/choose).
Include your macOS version, which transcription engine is shown in the sidebar, and
steps to reproduce.

## Project layout

See the **Files** table in the [README](README.md#files) for a one-line description of
every source file.

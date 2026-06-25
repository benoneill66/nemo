# Security Policy

Nemo is built around a simple privacy promise: **raw audio never leaves your Mac.**
Speech is transcribed on-device, and only distilled text is ever sent — and only to
your own logged-in Claude CLI. There are no servers, no telemetry, and no API keys.

## Where your data lives

Everything Nemo stores is plain JSON under `~/.config/nemo/data/` on your machine.
You can read, edit, or delete it at any time.

## Reporting a vulnerability

If you find a security or privacy issue — especially anything that could cause audio
or memory data to leak off-device — please report it privately rather than opening a
public issue.

- Use GitHub's [private vulnerability reporting](https://github.com/benoneill66/nemo/security/advisories/new), or
- Open a minimal public issue asking for a private contact channel (without details).

Please include the macOS version, the affected code path if known, and steps to
reproduce. We'll aim to acknowledge reports within a few days.

## Supported versions

This is a personal open-source project; fixes land on the latest release. Always run
the most recent version for security updates.

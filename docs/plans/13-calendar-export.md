# Plan 13 — Calendar / Reminders export

**Theme:** Reach · **Effort:** S · **Depends on:** — (richer with 05's editing UI)

## Goal

Let action items and dated commitments captured in memory optionally flow into Apple Reminders (and
calendar events into Calendar) via EventKit — so "I'll send the deck Friday" becomes an actual
reminder, not just a note in Nemo.

## Why

Nemo already extracts Action Items and dates into the `tasks` category (Models.swift:12,
Consolidator categorisation). But they stay trapped in Nemo. Pushing them into the OS task/calendar
system the user already lives in closes the loop from "captured" to "acted on" — a concrete,
high-utility payoff for the whole capture pipeline, with a native, on-device API (EventKit) that
fits the privacy model (no network).

## Current state

- Action Items are a first-class `Category` (`.tasks`), weighted highest in surfacing
  (Surfacer.swift:40). Memories carry `content` and timestamps but no structured due date.
- No EventKit usage; no export anywhere.

## Design

### 1. Extract a due date (cheap, optional)

Memories don't store a structured date today. Two paths:
- **On-device parse:** run `NSDataDetector(types: .date)` over a task memory's content/title to pull
  a due date when present. Free, no LLM. Good enough for "Friday", "next Tuesday", explicit dates.
- **Consolidator hint:** optionally have the consolidator emit a `due` field in its JSON for task
  memories (extend the `Draft` struct, Consolidator.swift:9, and the prompt's task example). More
  accurate for relative/contextual dates; gate behind the export feature so non-users don't pay for
  it.

Add `var due: Date? = nil` to `Memory` (defaulted; backward compatible).

### 2. Export action (EventKit)

- `EventKitExporter`:
  - `requestAccess()` — Reminders and/or Calendar authorization (Info.plist usage strings
    required: `NSRemindersFullAccessUsageDescription`, `NSCalendarsFullAccessUsageDescription`).
  - `exportReminder(for: Memory)` — create an `EKReminder` titled from the memory, notes =
    content + "via Nemo", due = `due` if present, in a dedicated "Nemo" list.
  - `exportEvent(for: Memory)` — for meeting-type memories with a date/time, create an `EKEvent`.
  - Track exported ids on the memory (`var exportedReminderId: String?`) to avoid duplicates and
    allow "open in Reminders".

### 3. Triggers (user-controlled, never silent)

- **Manual:** an "Add to Reminders" button on task memories in the Memory pane (pairs with plan
  05's detail sheet). This is the safe default.
- **Auto (opt-in):** if `autoExportTasks` is enabled, newly created `tasks` memories with a parsed
  `due` are exported automatically after consolidation, deduped by `exportedReminderId`.

## Files touched

- **New:** `Sources/Nemo/EventKitExporter.swift`.
- `Sources/Nemo/Models.swift` — `due`, `exportedReminderId`, optionally `exportedEventId`.
- `Sources/Nemo/Consolidator.swift` — optional `due` in `Draft` + prompt (behind feature flag).
- `Sources/Nemo/AppState.swift` — `exportToReminders(_:)`, optional auto-export after
  consolidation, `NSDataDetector` date parse.
- `Sources/Nemo/Panes.swift` — export button + "exported ✓ / open" state on task cards.
- `Info.plist` — EventKit usage description strings.
- `Sources/Nemo/Config.swift` — `calendarExportEnabled` (default false), `autoExportTasks`
  (default false), `remindersListName` (default "Nemo").

## Edge cases

- **Permission denied:** degrade to a clear message; keep the in-app memory. Never block capture on
  EventKit access.
- **Duplicate export:** guard on `exportedReminderId`; re-export updates the existing reminder
  rather than creating a new one.
- **No date:** export a reminder with no due date (still useful); don't fabricate a date.
- **Deleted in Reminders:** if the `EKReminder` no longer exists on re-export, recreate; treat the
  stored id as a best-effort link.
- **Backward compat:** new fields defaulted.

## Testing (see plan 07)

- Unit: `NSDataDetector` date extraction from sample task contents ("send Friday", explicit dates,
  no-date case).
- Unit: dedupe logic — exporting a memory twice doesn't create two reminders.
- Manual (can't fully unit-test EventKit): grant access, export a task, confirm it appears in the
  "Nemo" Reminders list with due date and notes; re-export updates rather than duplicates.

## Risks / open questions

- EventKit permission prompts and entitlements need care under hardened runtime / notarisation
  (the release workflow signs the app) — verify the usage strings and access requests work in the
  notarised build, not just `swift run`.
- Auto-export is powerful but surprising; keep it off by default and make the manual button the
  primary path until users trust the date extraction.

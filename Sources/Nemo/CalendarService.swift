import Foundation
import EventKit

/// Reads events from the user's macOS calendars and renders them as importable context.
///
/// macOS Calendar already syncs Google / iCloud / Exchange accounts on the user's behalf, so
/// "syncing in your calendar" is just reading whatever Calendar.app already holds via EventKit —
/// no separate OAuth, no network of our own. Access is on-device and requested only when the user
/// asks to sync. Only distilled text ever leaves the Mac, and only to the Claude CLI through the
/// existing import pipeline.
final class CalendarService {
    private let store = EKEventStore()

    // MARK: - A pulled event

    struct Event: Sendable {
        var id: String
        var title: String
        var start: Date
        var end: Date?
        var allDay: Bool
        var location: String
        var notes: String
        var attendees: [String]
        var calendarName: String

        /// Renders the event as a single import-friendly text block (mirrors Gmail's `asContext`).
        var asContext: String {
            var head = "### Event: \(title.isEmpty ? "(untitled)" : title)"
            var lines: [String] = []
            lines.append("When: \(Self.formatWhen(start: start, end: end, allDay: allDay))")
            if !location.isEmpty { lines.append("Location: \(location)") }
            if !attendees.isEmpty { lines.append("Attendees: \(attendees.joined(separator: ", "))") }
            if !calendarName.isEmpty { lines.append("Calendar: \(calendarName)") }
            head += "\n" + lines.joined(separator: "\n")
            let body = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? head : head + "\n\n" + body
        }

        private static func formatWhen(start: Date, end: Date?, allDay: Bool) -> String {
            let dayFmt = DateFormatter()
            dayFmt.dateStyle = .full
            dayFmt.timeStyle = .none
            if allDay {
                return dayFmt.string(from: start) + " (all day)"
            }
            let timeFmt = DateFormatter()
            timeFmt.dateStyle = .none
            timeFmt.timeStyle = .short
            var s = dayFmt.string(from: start) + ", " + timeFmt.string(from: start)
            if let end {
                // Same calendar day → just append the end time; otherwise spell out the end date.
                if Calendar.current.isDate(start, inSameDayAs: end) {
                    s += "–" + timeFmt.string(from: end)
                } else {
                    s += " – " + dayFmt.string(from: end) + ", " + timeFmt.string(from: end)
                }
            }
            return s
        }
    }

    // MARK: - Errors

    enum CalendarError: LocalizedError {
        case notAuthorized
        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Calendar access was denied. Grant Nemo access in System Settings → Privacy & Security → Calendars."
            }
        }
    }

    // MARK: - Access

    /// Whether Nemo already holds calendar (event) access, so the UI can show "Sync" vs "Grant access".
    static var hasAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return status == .fullAccess }
        return status == .authorized
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { cont in
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { granted, _ in cont.resume(returning: granted) }
            } else {
                store.requestAccess(to: .event) { granted, _ in cont.resume(returning: granted) }
            }
        }
    }

    // MARK: - Fetch

    /// Fetches events in `[now − pastDays, now + futureDays]`, soonest first, capped at `max`.
    /// `calendarNames` (when non-empty) restricts which calendars are read; otherwise all are used.
    func fetchEvents(pastDays: Int, futureDays: Int, max: Int,
                     calendarNames: [String] = []) async throws -> [Event] {
        guard await requestAccess() else { throw CalendarError.notAuthorized }

        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day, value: -Swift.max(0, pastDays), to: now) ?? now
        let end = cal.date(byAdding: .day, value: Swift.max(1, futureDays), to: now) ?? now

        let wanted = Set(calendarNames.map { $0.lowercased() })
        let calendars: [EKCalendar]? = wanted.isEmpty
            ? nil
            : store.calendars(for: .event).filter { wanted.contains($0.title.lowercased()) }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        // `events(matching:)` is synchronous and can be slow on large calendars — keep it off the
        // main actor.
        let ekEvents = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(max)

        return ekEvents.map { ev in
            Event(id: ev.eventIdentifier ?? UUID().uuidString,
                  title: ev.title ?? "",
                  start: ev.startDate,
                  end: ev.endDate,
                  allDay: ev.isAllDay,
                  location: ev.location ?? "",
                  notes: ev.notes ?? "",
                  attendees: (ev.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString },
                  calendarName: ev.calendar?.title ?? "")
        }
    }
}

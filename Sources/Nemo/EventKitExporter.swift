import Foundation
import EventKit

/// Pulls a due date out of free text using the system data detector (plan 13). Pure & testable.
enum DateExtractor {
    static func firstDate(in text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, range: range)?.date
    }
}

/// Exports action-item memories to Apple Reminders via EventKit (plan 13). On-device, no network;
/// access is requested only when the user asks to export. Dedupes by stored reminder id.
final class EventKitExporter {
    private let store = EKEventStore()

    func requestRemindersAccess() async -> Bool {
        await withCheckedContinuation { cont in
            if #available(macOS 14.0, *) {
                store.requestFullAccessToReminders { granted, _ in cont.resume(returning: granted) }
            } else {
                store.requestAccess(to: .reminder) { granted, _ in cont.resume(returning: granted) }
            }
        }
    }

    /// Create or update a reminder for `memory` in the list `listName`. Returns the reminder id
    /// (store it on the memory to dedupe / re-sync later).
    func exportReminder(memory: Memory, listName: String) throws -> String {
        let reminder: EKReminder
        if let id = memory.exportedReminderId,
           let existing = store.calendarItem(withIdentifier: id) as? EKReminder {
            reminder = existing
        } else {
            reminder = EKReminder(eventStore: store)
        }
        reminder.title = memory.title
        reminder.notes = memory.content + "\n\nvia Nemo"
        if let due = memory.due {
            reminder.dueDateComponents = Calendar.current
                .dateComponents([.year, .month, .day, .hour, .minute], from: due)
        }
        reminder.calendar = try remindersList(named: listName)
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    /// Find or create the named Reminders list.
    private func remindersList(named name: String) throws -> EKCalendar {
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == name }) { return existing }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = name
        cal.source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first { $0.sourceType == .local }
            ?? store.sources.first
        try store.saveCalendar(cal, commit: true)
        return cal
    }
}

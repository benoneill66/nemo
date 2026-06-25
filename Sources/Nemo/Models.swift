import Foundation

// MARK: - Categories

/// The default memory categories Nemo organizes things into. The consolidator
/// is told these names but may coin its own; unknown categories fall back to `.misc`
/// styling. Kept as a String on `Memory` so the LLM isn't boxed in.
enum Category: String, CaseIterable, Codable {
    case people      = "People"
    case projects    = "Projects"
    case decisions   = "Decisions"
    case tasks       = "Action Items"
    case preferences = "Preferences"
    case facts       = "Facts"
    case meetings    = "Meetings"
    case ideas       = "Ideas"
    case questions   = "Open Questions"
    case misc        = "Misc"

    static func match(_ raw: String) -> Category {
        if let exact = Category(rawValue: raw) { return exact }
        let l = raw.lowercased()
        return Category.allCases.first { $0.rawValue.lowercased() == l }
            ?? Category.allCases.first { l.contains($0.rawValue.lowercased()) }
            ?? .misc
    }

    /// SF Symbol used in the UI.
    var symbol: String {
        switch self {
        case .people:      return "person.2.fill"
        case .projects:    return "folder.fill"
        case .decisions:   return "checkmark.seal.fill"
        case .tasks:       return "checklist"
        case .preferences: return "heart.fill"
        case .facts:       return "lightbulb.fill"
        case .meetings:    return "person.3.sequence.fill"
        case .ideas:       return "sparkles"
        case .questions:   return "questionmark.circle.fill"
        case .misc:        return "tray.full.fill"
        }
    }

    /// A hue (0–1) used to tint glass cards per category.
    var hue: Double {
        switch self {
        case .people:      return 0.58
        case .projects:    return 0.72
        case .decisions:   return 0.40
        case .tasks:       return 0.08
        case .preferences: return 0.92
        case .facts:       return 0.14
        case .meetings:    return 0.52
        case .ideas:       return 0.80
        case .questions:   return 0.00
        case .misc:        return 0.62
        }
    }
}

// MARK: - Transcript

/// One contiguous chunk of recognized speech with timing. Segments are the raw
/// material the consolidator turns into memories.
struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var text: String
    var start: Date
    var end: Date
    var marked: Bool = false           // flagged important by a spoken keyword
    var markers: [String] = []         // which keyword(s) triggered the flag
    var sessionId: UUID? = nil         // owning session (meeting / ambient day)
    var consolidated: Bool = false     // already folded into memory
}

// MARK: - Memory

/// A distilled, durable piece of knowledge. Memories are interconnected via `links`
/// (related memory ids) and share `entities` (people/projects/things) so the graph
/// can be traversed and rendered.
struct Memory: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var content: String
    var category: String = Category.misc.rawValue
    var entities: [String] = []
    var links: [UUID] = []
    var importance: Int = 2            // 1…5, 5 = most important
    var source: String = "transcript"  // "transcript" | "import:<assistant>" | "manual"
    var created: Date = Date()
    var updated: Date = Date()

    var categoryEnum: Category { Category.match(category) }
}

// MARK: - Session

/// A bounded period of listening. The "ambient" session rolls per day; the user can
/// also start a named session (e.g. a meeting) to group everything said while active.
struct Session: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var kind: Kind = .ambient
    var start: Date = Date()
    var end: Date? = nil
    var summary: String? = nil         // filled in by the consolidator when closed

    enum Kind: String, Codable { case ambient, meeting }

    var isOpen: Bool { end == nil }
}

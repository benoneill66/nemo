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
    var speaker: Int? = nil            // diarization cluster id (0-based); nil = unattributed
    var redacted: Bool = false         // sensitive content was masked before storage (plan 06)
}

// MARK: - Speaker

/// A distinct voice the diarizer has picked out, with the centroid of its voice fingerprints so
/// the same person re-matches across sessions and app launches. Starts life as "Speaker N" and
/// can be renamed by the user. Entirely on-device — the centroid is acoustic features, not audio.
struct SpeakerIdentity: Codable, Identifiable, Hashable {
    var id: Int                        // matches TranscriptSegment.speaker
    var name: String
    var centroid: [Float] = []         // running mean of this voice's fingerprints
    var count: Int = 0                 // fingerprints folded in (confidence in the centroid)
    var renamed: Bool = false          // user gave it a real name (vs. the default "Speaker N")
    var firstSeen: Date = Date()

    /// A stable, pleasant hue per speaker for chips/labels in the UI.
    var hue: Double {
        let golden = 0.61803398875
        return (0.07 + Double(id) * golden).truncatingRemainder(dividingBy: 1)
    }
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
    var importance: Int = 2            // 1…5, 5 = most important (user/LLM-set base)
    var source: String = "transcript"  // "transcript" | "import:<assistant>" | "manual"
    var created: Date = Date()
    var updated: Date = Date()

    // Reinforcement / decay (plan 02) — learned usage signal kept separate from `importance`.
    var hitCount: Int = 0              // times surfaced as relevant
    var lastSurfaced: Date? = nil      // most recent surfacing
    var weight: Double = 0             // learned reinforcement, added to importance for ranking

    // Editing, pinning & provenance (plan 05).
    var pinned: Bool = false           // user-pinned: automation won't decay/override it
    var userEdited: Bool = false       // user edited the text: dedup/merge won't clobber it
    var sourceSegmentIds: [UUID] = []  // transcript segments this memory was distilled from

    // Contradiction / supersede (plan 04).
    var superseded: Bool = false       // archived: a newer memory overrides this fact
    var supersededBy: UUID? = nil      // the memory that replaced it
    var history: [String] = []         // short human notes of what changed, newest last

    // Calendar / Reminders export (plan 13).
    var due: Date? = nil               // parsed due date for action items
    var exportedReminderId: String? = nil  // EKReminder identifier, if exported

    var categoryEnum: Category { Category.match(category) }

    /// Ranking importance = user/LLM base + learned reinforcement, clamped to a sane range.
    var effectiveImportance: Double { Double(importance) + max(0, weight) }
}

// MARK: - Briefing

/// A short daily catch-up Nemo generates from the memory graph and recent sessions —
/// open action items, unanswered questions, what happened yesterday, what matters today.
/// Cached on disk so reopening the app shows today's briefing without regenerating.
struct Briefing: Codable, Hashable {
    var text: String
    var generated: Date

    var isFromToday: Bool { Calendar.current.isDateInToday(generated) }
}

// MARK: - Surfaced memory

/// A memory the relevance engine has surfaced because it's relevant to what's being said
/// right now. Lives only in memory (not persisted) and decays out as the conversation moves on.
struct SurfacedMemory: Identifiable, Hashable {
    var memory: Memory
    var score: Double
    var reason: String
    var firstSeen: Date          // when it first surfaced this run (drives the "new" pulse)
    var lastHit: Date            // last time it matched, drives time decay / pruning

    var id: UUID { memory.id }
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

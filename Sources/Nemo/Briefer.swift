import Foundation

/// Builds a daily "here's where things stand" briefing from the memory graph and recent
/// sessions. Where the live Surfacer answers "what's relevant to this sentence", the Briefer
/// answers "what should be on your mind today" — the open action items, unanswered questions,
/// fresh decisions, and what yesterday's sessions were about — synthesized by Claude into a
/// short, spoken-style catch-up.
enum Briefer {

    private static let system = """
    You are a personal assistant giving the user a short morning briefing, read aloud. \
    You are given structured notes from their own memory: open action items, unanswered \
    questions, recent decisions, and summaries of recent sessions. Produce a warm, concise \
    briefing in plain spoken English — no markdown, headers, bullet characters, or URLs. \
    Open with a brief one-line greeting. Then, in a few short sentences, tell them what's \
    outstanding and what's worth their attention today: lead with action items and open \
    questions, mention anything time-sensitive, and weave in relevant context from recent \
    sessions. Be specific and reference real names and items from the notes. If there's \
    little to report, say so briefly and cheerfully. Keep the whole thing under about 150 words.
    """

    /// Generate today's briefing. Throws if the Claude CLI is unavailable or returns nothing.
    static func generate(memories: [Memory], sessions: [Session], model: String?) async throws -> String {
        let prompt = buildPrompt(memories: memories, sessions: sessions)
        return try await AssistantRunner.claudeOneShot(prompt: prompt, system: system, model: model,
                                                       feature: "brief")
    }

    /// Assemble the structured notes Claude briefs from. Bounded so the prompt stays small.
    private static func buildPrompt(memories: [Memory], sessions: [Session]) -> String {
        let now = Date()
        let cal = Calendar.current
        let dayName: String = {
            let f = DateFormatter(); f.dateFormat = "EEEE, d MMMM"; return f.string(from: now)
        }()

        func list(_ cat: Category, max: Int) -> [Memory] {
            memories.filter { $0.categoryEnum == cat }
                .sorted { $0.importance != $1.importance ? $0.importance > $1.importance
                                                         : $0.updated > $1.updated }
                .prefix(max).map { $0 }
        }
        func render(_ mems: [Memory]) -> String {
            mems.map { "- \($0.title): \($0.content)" }.joined(separator: "\n")
        }

        let actions   = list(.tasks, max: 8)
        let questions = list(.questions, max: 5)
        let decisions = list(.decisions, max: 4)

        // Recent high-signal context: things touched in the last ~3 days, and recent
        // session summaries (e.g. yesterday's meetings).
        let threeDaysAgo = cal.date(byAdding: .day, value: -3, to: now) ?? now
        let recentMems = memories
            .filter { $0.updated >= threeDaysAgo && $0.importance >= 3 }
            .sorted { $0.updated > $1.updated }
            .prefix(6).map { $0 }

        let recentSessions = sessions
            .filter { ($0.end ?? $0.start) >= threeDaysAgo }
            .compactMap { s -> String? in
                guard let sum = s.summary, !sum.isEmpty else { return nil }
                return "- \(s.title): \(sum)"
            }
            .suffix(5)
            .joined(separator: "\n")

        func section(_ title: String, _ body: String) -> String {
            body.isEmpty ? "" : "\n\(title):\n\(body)\n"
        }

        let body =
            section("OPEN ACTION ITEMS", render(actions)) +
            section("OPEN QUESTIONS", render(questions)) +
            section("RECENT DECISIONS", render(decisions)) +
            section("RECENTLY ON YOUR MIND", render(recentMems)) +
            section("RECENT SESSIONS", recentSessions)

        let notes = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Today is \(dayName). Here are notes from the user's memory to brief them on.
        \(notes.isEmpty ? "(There is very little on record right now.)" : notes)

        Give the morning briefing now.
        """
    }
}

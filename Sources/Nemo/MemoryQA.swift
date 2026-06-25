import Foundation

/// Assembles the grounded prompt for spoken "Hey Nemo" questions (plan 11): retrieve the user's
/// own relevant memories and answer from them first, falling back to general knowledge/web search
/// when they don't cover the question. Pure & testable — `AppState` does the retrieval.
enum MemoryQA {
    static let system = """
    You are Nemo, the user's personal memory assistant, answering out loud. Prefer answering from \
    the MEMORIES below when they are relevant to the question — they are the user's own saved \
    knowledge. If the memories don't cover it, say so briefly and answer from general knowledge, \
    using web search for anything current. Reply in one to three short, conversational sentences \
    of plain spoken English — no markdown, lists, code, emoji, URLs, or citations.
    """

    static func prompt(question: String, memories: [Memory], recent: String) -> String {
        let mem = memories.isEmpty ? "(no stored memories matched this question)"
            : memories.map { "- [\($0.category)] \"\($0.title)\" — \($0.content)" }.joined(separator: "\n")
        let recentBlock = recent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "" : "\nRECENT CONVERSATION:\n\(recent)\n"
        return """
        MEMORIES:
        \(mem)
        \(recentBlock)
        QUESTION: \(question)
        """
    }
}

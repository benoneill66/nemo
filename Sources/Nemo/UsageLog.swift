import Foundation

/// One metered LLM (Claude CLI) invocation — metadata only, never prompt/response text (plan 09).
struct UsageEvent: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var feature: String        // "consolidate" | "gate" | "brief" | "import" | "answer"
    var model: String
    var at: Date = Date()
    var durationMs: Int
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
    var outcome: String        // "ok" | "rate_limited" | "failed" | "timeout"
    var droppedSegments: Int? = nil   // gate only
}

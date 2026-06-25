import Foundation

/// One metered LLM (Claude CLI) invocation — metadata only, never prompt/response text (plan 09).
struct UsageEvent: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var feature: String        // "consolidate" | "gate" | "brief" | "import" | "answer"
    var model: String
    var at: Date = Date()
    var durationMs: Int        // 0 marks a synthetic summary event (e.g. gate drop counts)
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
    var estimated: Bool = false // tokens are char-count estimates, not reported by the API
    var outcome: String        // "ok" | "rate_limited" | "failed" | "timeout"
    var keptSegments: Int? = nil      // gate only
    var droppedSegments: Int? = nil   // gate only

    /// Real CLI calls have measured duration; synthetic summary rows have 0.
    var isCall: Bool { durationMs > 0 }
}

/// Aggregate view over a window of usage events (plan 09).
struct UsageRollup {
    var calls: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var estimatedCost: Double = 0
    var anyEstimated: Bool = false
    var byFeature: [String: Int] = [:]   // call count per feature
    var failureRate: Double = 0          // fraction of calls that didn't succeed
    var gateKept: Int = 0
    var gateDropped: Int = 0

    /// Fraction of gated segments the cheap relevance pass discarded, or nil if the gate hasn't run.
    var gateDropRate: Double? {
        let total = gateKept + gateDropped
        return total > 0 ? Double(gateDropped) / Double(total) : nil
    }
}

extension Array where Element == UsageEvent {
    /// Roll up the events at or after `since` into totals, per-feature counts, and gate stats.
    func rollup(since: Date) -> UsageRollup {
        var r = UsageRollup()
        var failures = 0
        for e in self where e.at >= since {
            // Gate drop counts ride on synthetic (duration-0) summary rows.
            r.gateKept += e.keptSegments ?? 0
            r.gateDropped += e.droppedSegments ?? 0
            guard e.isCall else { continue }
            r.calls += 1
            r.byFeature[e.feature, default: 0] += 1
            if e.outcome != "ok" { failures += 1 }
            let inTok = e.inputTokens ?? 0, outTok = e.outputTokens ?? 0
            r.inputTokens += inTok
            r.outputTokens += outTok
            if e.estimated { r.anyEstimated = true }
            r.estimatedCost += Pricing.cost(model: e.model, inputTokens: inTok, outputTokens: outTok)
        }
        r.failureRate = r.calls > 0 ? Double(failures) / Double(r.calls) : 0
        return r
    }
}

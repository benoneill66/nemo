import Foundation

/// Rough cost estimation for metered Claude usage (plan 09). The Claude CLI may be covered by a
/// subscription rather than billed per-token, so these are estimates of the *equivalent* API spend,
/// shown clearly as "est." in the UI. Prices are USD per 1M tokens (input, output).
///
/// Last updated 2026-06; keep this table as the single place to refresh pricing.
enum Pricing {
    static let table: [String: (input: Double, output: Double)] = [
        "claude-opus-4-8":   (5.0, 25.0),
        "claude-sonnet-4-6": (3.0, 15.0),
        "claude-haiku-4-5":  (0.8, 4.0),
    ]

    private static let fallback = (input: 3.0, output: 15.0)

    /// Estimated USD cost for one call's token counts. Matches on a model-id substring so versioned
    /// ids ("claude-sonnet-4-6", "claude-sonnet-4-6[1m]") all resolve.
    static func cost(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let p = table.first { model.contains($0.key) }?.value ?? fallback
        return Double(inputTokens) / 1_000_000 * p.input + Double(outputTokens) / 1_000_000 * p.output
    }
}

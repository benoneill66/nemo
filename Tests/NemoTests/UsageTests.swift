import XCTest
@testable import Nemo

final class UsageTests: XCTestCase {

    func testRollupAggregatesCallsTokensAndFeatures() {
        let now = Date()
        let events = [
            UsageEvent(feature: "consolidate", model: "claude-sonnet-4-6", at: now, durationMs: 100,
                       inputTokens: 1000, outputTokens: 500, outcome: "ok"),
            UsageEvent(feature: "gate", model: "claude-haiku-4-5", at: now, durationMs: 50,
                       inputTokens: 200, outputTokens: 20, outcome: "ok"),
            UsageEvent(feature: "gate", model: "claude-haiku-4-5", at: now, durationMs: 60,
                       outcome: "failed"),
            // synthetic gate-outcome row (duration 0) — not a call, carries drop stats
            UsageEvent(feature: "gate", model: "claude-haiku-4-5", at: now, durationMs: 0,
                       outcome: "ok", keptSegments: 4, droppedSegments: 6),
        ]
        let r = events.rollup(since: now.addingTimeInterval(-3600))
        XCTAssertEqual(r.calls, 3)                       // duration-0 row excluded
        XCTAssertEqual(r.inputTokens, 1200)
        XCTAssertEqual(r.outputTokens, 520)
        XCTAssertEqual(r.byFeature["gate"], 2)
        XCTAssertEqual(r.byFeature["consolidate"], 1)
        XCTAssertEqual(r.gateDropRate, 0.6)
        XCTAssertEqual(r.failureRate, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testRollupRespectsSinceWindow() {
        let now = Date()
        let old = UsageEvent(feature: "brief", model: "m", at: now.addingTimeInterval(-7200),
                             durationMs: 10, outcome: "ok")
        let recent = UsageEvent(feature: "brief", model: "m", at: now, durationMs: 10, outcome: "ok")
        let r = [old, recent].rollup(since: now.addingTimeInterval(-3600))
        XCTAssertEqual(r.calls, 1)
    }

    func testPricingResolvesVersionedModelIds() {
        // 1M input + 1M output of sonnet = 3 + 15.
        XCTAssertEqual(Pricing.cost(model: "claude-sonnet-4-6[1m]", inputTokens: 1_000_000, outputTokens: 1_000_000),
                       18.0, accuracy: 1e-6)
        XCTAssertEqual(Pricing.cost(model: "claude-haiku-4-5", inputTokens: 1_000_000, outputTokens: 0),
                       0.8, accuracy: 1e-6)
    }

    func testUsageTokensParsesStreamLine() {
        let line = #"{"type":"stream_event","event":{"type":"message_delta","usage":{"input_tokens":120,"output_tokens":45}}}"#.data(using: .utf8)!
        let u = AssistantRunner.usageTokens(fromLine: line)
        XCTAssertEqual(u?.input, 120)
        XCTAssertEqual(u?.output, 45)
    }

    func testUsageTokensIgnoresNonUsageLine() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_stop"}}"#.data(using: .utf8)!
        XCTAssertNil(AssistantRunner.usageTokens(fromLine: line))
    }
}

import XCTest
@testable import Nemo

final class AssistantErrorTests: XCTestCase {

    func testClassifyNotAuthenticated() {
        let e = AssistantError.classify(status: 1, stderr: "Error: Not logged in. Please run claude login", timedOut: false)
        guard case .notAuthenticated = e else { return XCTFail("expected notAuthenticated, got \(e)") }
        XCTAssertFalse(e.isTransient)
        XCTAssertTrue(e.isHardDown)
    }

    func testClassifyRateLimitedParsesRetryAfter() {
        let e = AssistantError.classify(status: 1, stderr: "429 rate limit exceeded, retry-after: 45", timedOut: false)
        guard case .rateLimited(let after) = e else { return XCTFail("expected rateLimited, got \(e)") }
        XCTAssertEqual(after, 45)
        XCTAssertTrue(e.isTransient)
        XCTAssertFalse(e.isHardDown)
    }

    func testClassifyTimeoutTakesPriority() {
        let e = AssistantError.classify(status: 15, stderr: "anything", timedOut: true)
        guard case .timedOut = e else { return XCTFail("expected timedOut, got \(e)") }
        XCTAssertTrue(e.isTransient)
    }

    func testClassifyGenericFailure() {
        let e = AssistantError.classify(status: 2, stderr: "some unknown problem", timedOut: false)
        guard case .failed = e else { return XCTFail("expected failed, got \(e)") }
        XCTAssertTrue(e.isTransient)   // generic failures retry
    }

    func testOutcomeStringMapping() {
        XCTAssertEqual(AssistantRunner.outcomeString(for: .rateLimited(retryAfter: nil)), "rate_limited")
        XCTAssertEqual(AssistantRunner.outcomeString(for: .timedOut), "timeout")
        XCTAssertEqual(AssistantRunner.outcomeString(for: .notInstalled), "failed")
    }
}

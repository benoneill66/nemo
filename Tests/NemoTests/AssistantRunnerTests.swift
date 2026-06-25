import XCTest
@testable import Nemo

final class AssistantRunnerTests: XCTestCase {

    func testSpokenStripsMarkdownLinksAndFormatting() {
        let input = "Check [the docs](https://example.com) for **info** now."
        XCTAssertEqual(AssistantRunner.spoken(from: input), "Check the docs for info now.")
    }

    func testSpokenRemovesSourcesBlockAndBullets() {
        let input = "Here you go:\n- one\n- two\nSources: https://a.com, https://b.com"
        let out = AssistantRunner.spoken(from: input)
        XCTAssertFalse(out.lowercased().contains("sources"))
        XCTAssertFalse(out.contains("- "))
        XCTAssertTrue(out.contains("one"))
        XCTAssertTrue(out.contains("two"))
    }

    func testTextDeltaExtractsText() {
        let line = """
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}}
        """.data(using: .utf8)!
        XCTAssertEqual(AssistantRunner.textDelta(fromLine: line), "hello")
    }

    func testTextDeltaIgnoresOtherLines() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_stop"}}"#.data(using: .utf8)!
        XCTAssertNil(AssistantRunner.textDelta(fromLine: line))
        XCTAssertTrue(AssistantRunner.isContentBlockStop(fromLine: line))
    }
}

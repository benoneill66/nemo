import XCTest
@testable import Nemo

final class MemoryQATests: XCTestCase {

    func testPromptIncludesMemoriesAndQuestion() {
        let m = Memory(title: "Q3 deadline", content: "Oct 15", category: Nemo.Category.decisions.rawValue)
        let p = MemoryQA.prompt(question: "when's the deadline?", memories: [m], recent: "we were chatting")
        XCTAssertTrue(p.contains("Q3 deadline"))
        XCTAssertTrue(p.contains("[Decisions]"))
        XCTAssertTrue(p.contains("QUESTION: when's the deadline?"))
        XCTAssertTrue(p.contains("RECENT CONVERSATION:"))
    }

    func testPromptHandlesNoMemoriesAndNoRecent() {
        let p = MemoryQA.prompt(question: "what's the weather?", memories: [], recent: "   ")
        XCTAssertTrue(p.contains("no stored memories matched"))
        XCTAssertFalse(p.contains("RECENT CONVERSATION:"))   // blank recent omitted
        XCTAssertTrue(p.contains("QUESTION: what's the weather?"))
    }
}

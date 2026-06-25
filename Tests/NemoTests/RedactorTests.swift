import XCTest
@testable import Nemo

final class RedactorTests: XCTestCase {

    func testMasksSpokenPasswordKeepingTrigger() {
        let (clean, did) = Redactor.scrub("ok so my password is hunter2 alright")
        XCTAssertTrue(did)
        XCTAssertTrue(clean.contains("password is \(Redactor.mask)"))
        XCTAssertFalse(clean.contains("hunter2"))
    }

    func testMasksLongDigitRuns() {
        let (clean, did) = Redactor.scrub("the card number is 4111 1111 1111 1111 thanks")
        XCTAssertTrue(did)
        XCTAssertFalse(clean.contains("4111"))
    }

    func testLeavesOrdinarySpeechIntact() {
        let (clean, did) = Redactor.scrub("let's meet Sarah at three about the Q3 launch")
        XCTAssertFalse(did)
        XCTAssertEqual(clean, "let's meet Sarah at three about the Q3 launch")
    }

    func testIsIdempotent() {
        let once = Redactor.scrub("my pin is 482931").clean
        let twice = Redactor.scrub(once).clean
        XCTAssertEqual(once, twice)
    }
}

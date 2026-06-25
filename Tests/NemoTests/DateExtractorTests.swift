import XCTest
@testable import Nemo

final class DateExtractorTests: XCTestCase {

    func testExtractsExplicitDate() {
        let d = DateExtractor.firstDate(in: "Send the deck by January 15, 2027")
        XCTAssertNotNil(d)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: d!)
        XCTAssertEqual(comps.year, 2027)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 15)
    }

    func testNoDateReturnsNil() {
        XCTAssertNil(DateExtractor.firstDate(in: "remember to call the plumber sometime"))
    }
}

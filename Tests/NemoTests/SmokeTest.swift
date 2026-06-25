import XCTest
@testable import Nemo

/// Confirms `@testable import Nemo` against the executable target works on this toolchain.
/// (The substantive tests live in the other files in this target.)
final class SmokeTest: XCTestCase {
    func testTestTargetWiredUp() {
        XCTAssertEqual(Surfacer.tokens("Hello, the World"), ["hello", "world"])
    }
}

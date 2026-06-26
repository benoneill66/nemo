import XCTest
@testable import Nemo

/// Regression: a Memory persisted before plan 17 has no `stage`/`retention`/`archivedAt` keys.
/// Decoding such a row must still succeed (defaults applied), or upgrading wipes the whole store.
final class MemoryDecodeTests: XCTestCase {
    func testDecodesPrePlan17Row() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Old","content":"x","category":"Facts",
         "entities":[],"links":[],"importance":3,"source":"transcript",
         "created":"2026-06-01T00:00:00Z","updated":"2026-06-01T00:00:00Z",
         "hitCount":0,"weight":0,"pinned":false,"userEdited":false,
         "sourceSegmentIds":[],"superseded":false,"history":[]}
        """
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let m = try d.decode(Memory.self, from: Data(json.utf8))
        XCTAssertEqual(m.stage, .episodic)
        XCTAssertEqual(m.retention, 1.0, accuracy: 1e-9)
        XCTAssertNil(m.archivedAt)
    }
}

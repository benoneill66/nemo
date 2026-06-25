import XCTest
@testable import Nemo

final class ProvenanceTests: XCTestCase {

    func testCreatedMemoryCarriesSourceSegmentIds() {
        let ids = [UUID(), UUID(), UUID()]
        let out = Consolidator.merge(drafts: [Consolidator.Draft(title: "A", content: "x")],
                                     into: [], summary: nil, source: "transcript",
                                     sourceSegmentIds: ids)
        XCTAssertEqual(out.memories.first?.sourceSegmentIds, ids)
    }

    func testProvenanceIsCappedAt20() {
        let ids = (0..<40).map { _ in UUID() }
        let out = Consolidator.merge(drafts: [Consolidator.Draft(title: "A", content: "x")],
                                     into: [], summary: nil, source: "transcript",
                                     sourceSegmentIds: ids)
        XCTAssertEqual(out.memories.first?.sourceSegmentIds.count, 20)
        XCTAssertEqual(out.memories.first?.sourceSegmentIds, Array(ids.suffix(20)))
    }

    func testUserEditedMemoryTextNotClobberedOnUpdate() {
        var existing = Memory(title: "Deadline", content: "user wrote this")
        existing.userEdited = true
        let out = Consolidator.merge(drafts: [Consolidator.Draft(title: "deadline", content: "model rewrite",
                                                                 entities: ["Q3"])],
                                     into: [existing], summary: nil, source: "transcript")
        XCTAssertEqual(out.memories.first?.content, "user wrote this")   // text preserved
        XCTAssertEqual(out.memories.first?.entities, ["Q3"])            // metadata still enriched
    }
}

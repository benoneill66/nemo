import XCTest
@testable import Nemo

final class SupersedeTests: XCTestCase {

    func testApplySupersedeArchivesOlderAndNotesHistory() {
        let older = Memory(title: "Deadline Sept 30", content: "due end of Q3")
        let newer = Memory(title: "Deadline Oct 15", content: "moved out two weeks")
        let action = Consolidator.SupersedeAction(newer: newer.id, older: older.id,
                                                  note: "deadline moved Sep 30 -> Oct 15")
        let result = Consolidator.applySupersede([older, newer], [action])

        let o = result.first { $0.id == older.id }!
        let n = result.first { $0.id == newer.id }!
        XCTAssertTrue(o.superseded)
        XCTAssertEqual(o.supersededBy, newer.id)
        XCTAssertFalse(n.superseded)
        XCTAssertEqual(n.history, ["deadline moved Sep 30 -> Oct 15"])
    }

    func testApplySupersedeSkipsAlreadyArchived() {
        var older = Memory(title: "A", content: "x"); older.superseded = true
        let newer = Memory(title: "B", content: "y")
        let result = Consolidator.applySupersede([older, newer],
            [.init(newer: newer.id, older: older.id, note: "n")])
        XCTAssertTrue(result.first { $0.id == newer.id }!.history.isEmpty)  // no double-archive
    }

    func testContradictionPairsNominatesSharedEntityActionable() {
        let a = Memory(title: "Q3 deadline", content: "Sep 30", category: Nemo.Category.decisions.rawValue, entities: ["Q3"])
        let b = Memory(title: "Q3 deadline moved", content: "Oct 15", category: Nemo.Category.decisions.rawValue, entities: ["Q3"])
        let c = Memory(title: "Lunch", content: "pizza", category: Nemo.Category.misc.rawValue, entities: ["Q3"])
        let pairs = Consolidator.contradictionPairs([a, b, c])
        XCTAssertEqual(pairs.count, 1)   // a&b actionable + shared entity; c is misc → excluded
    }

    func testLiveHeadResolvesChain() {
        var a = Memory(title: "A", content: "")
        var b = Memory(title: "B", content: "")
        let c = Memory(title: "C", content: "")
        a.superseded = true; a.supersededBy = b.id
        b.superseded = true; b.supersededBy = c.id
        let byId = Dictionary(uniqueKeysWithValues: [a, b, c].map { ($0.id, $0) })
        XCTAssertEqual(Consolidator.liveHead(a.id, in: byId), c.id)
    }
}

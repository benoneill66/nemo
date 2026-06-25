import XCTest
@testable import Nemo

final class SurfacerHybridTests: XCTestCase {

    private func mem(_ title: String, _ content: String = "",
                     category: Nemo.Category = .facts, entities: [String] = []) -> Memory {
        Memory(title: title, content: content, category: category.rawValue, entities: entities)
    }

    func testPureSemanticMatchSurfacesWithRelatedReason() {
        // No lexical overlap at all, but a strong semantic neighbour → should surface.
        let m = mem("Quarterly planning", "deadline for the launch")
        let sem = [m.id: 0.9]
        let hits = Surfacer.rankHybrid(recent: "totally unrelated words here", memories: [m],
                                       semantic: sem, semanticWeight: 4, semanticFloor: 0.3, minScore: 1)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits.first?.reason.hasPrefix("Related:") ?? false)
    }

    func testSubFloorSemanticIsIgnored() {
        let m = mem("Quarterly planning", "deadline for the launch")
        let hits = Surfacer.rankHybrid(recent: "totally unrelated words here", memories: [m],
                                       semantic: [m.id: 0.2], semanticWeight: 4, semanticFloor: 0.3, minScore: 1)
        XCTAssertTrue(hits.isEmpty)   // below floor and no lexical anchor
    }

    func testLexicalPlusSemanticOutranksLexicalOnly() {
        let both = mem("Alpha", category: .facts, entities: ["widget"])
        let lexOnly = mem("Beta", category: .facts, entities: ["widget"])
        let sem = [both.id: 0.95]   // only `both` also has a semantic match
        let hits = Surfacer.rankHybrid(recent: "the widget update", memories: [lexOnly, both],
                                       semantic: sem, semanticWeight: 4, semanticFloor: 0.3, minScore: 1)
        XCTAssertEqual(hits.first?.memory.id, both.id)
    }

    func testNoSemanticDictMatchesPlainRank() {
        // With an empty semantic dict, hybrid should reduce to the lexical anchor behaviour.
        let m = mem("Catch up", category: .tasks, entities: ["Sarah"])
        let hits = Surfacer.rankHybrid(recent: "follow up with Sarah", memories: [m],
                                       semantic: [:], minScore: 3)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.reason.hasPrefix("Mentioned:"), true)
    }
}

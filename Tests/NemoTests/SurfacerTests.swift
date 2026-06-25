import XCTest
@testable import Nemo

final class SurfacerTests: XCTestCase {

    func testTokensDropsStopwordsAndShortWords() {
        XCTAssertEqual(Surfacer.tokens("The quick fox"), ["quick", "fox"])      // "the" stopword, all >=3
        XCTAssertEqual(Surfacer.tokens("a I to ok"), [])                         // all too short / stop
        XCTAssertEqual(Surfacer.tokens("Q3-launch, plan!"), ["launch", "plan"]) // "q3" len2 dropped, split on punct
    }

    private func mem(_ title: String, _ content: String = "",
                     category: Nemo.Category = .facts, entities: [String] = [],
                     importance: Int = 2) -> Memory {
        Memory(title: title, content: content, category: category.rawValue,
               entities: entities, importance: importance)
    }

    func testEntityAnchorSurfaces() {
        let m = mem("Catch up", category: .tasks, entities: ["Sarah"])
        let hits = Surfacer.rank(recent: "I need to follow up with Sarah tomorrow", memories: [m])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.memory.id, m.id)
        XCTAssertTrue(hits.first?.matched.contains("Sarah") ?? false)
    }

    func testMultiWordEntityRequiresAllSignificantWords() {
        // Title "Deal" shares nothing with the recent text, so the entity is the only possible anchor.
        let m = mem("Deal", category: .projects, entities: ["Acme contract"])
        // Full phrase present → matches.
        XCTAssertEqual(Surfacer.rank(recent: "the Acme contract renews soon", memories: [m]).count, 1)
        // Only one of the two significant words present → no phrase/token match → no hit.
        XCTAssertTrue(Surfacer.rank(recent: "the contract is signed", memories: [m]).isEmpty)
    }

    func testPureContentOverlapDoesNotSurface() {
        // No entity, title shares nothing with recent text → content-only overlap is not enough.
        let m = mem("Misc note", "the quarterly deadline matters", category: .misc)
        XCTAssertTrue(Surfacer.rank(recent: "what is the deadline", memories: [m]).isEmpty)
    }

    func testCategoryWeightingOrdersResults() {
        // Same single-entity anchor; the higher-weighted category (tasks > facts) ranks first.
        let task = mem("Do thing", category: .tasks, entities: ["widget"])
        let fact = mem("About thing", category: .facts, entities: ["widget"])
        let hits = Surfacer.rank(recent: "the widget needs attention", memories: [fact, task])
        XCTAssertEqual(hits.first?.memory.id, task.id)
    }
}

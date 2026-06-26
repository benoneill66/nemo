import XCTest
@testable import Nemo

final class ConsolidatorParseTests: XCTestCase {
    private struct Probe: Decodable, Equatable { var relevant: [Int] }

    func testStripsJSONFences() throws {
        let p: Probe = try Consolidator.parseJSON("```json\n{\"relevant\":[1,2]}\n```")
        XCTAssertEqual(p, Probe(relevant: [1, 2]))
    }

    func testIsolatesObjectAmidProse() throws {
        let p: Probe = try Consolidator.parseJSON("Sure! {\"relevant\":[3]} hope that helps")
        XCTAssertEqual(p, Probe(relevant: [3]))
    }

    func testThrowsOnJunk() {
        XCTAssertThrowsError(try { let _: Probe = try Consolidator.parseJSON("no json here") }())
    }
}

final class ConsolidatorMergeTests: XCTestCase {

    private func draft(_ title: String, _ content: String = "note",
                       category: String? = nil, entities: [String]? = nil,
                       related: [String]? = nil, importance: Int? = nil) -> Consolidator.Draft {
        Consolidator.Draft(title: title, content: content, category: category,
                           entities: entities, related: related, importance: importance)
    }

    func testCreatesNewMemory() {
        let out = Consolidator.merge(drafts: [draft("Deadline", category: "Decisions")],
                                     into: [], summary: nil, source: "transcript")
        XCTAssertEqual(out.created, 1)
        XCTAssertEqual(out.updated, 0)
        XCTAssertEqual(out.memories.first?.categoryEnum, .decisions)
    }

    func testUpdatesByExactLowercasedTitleAndRatchetsImportance() {
        let existing = Memory(title: "Q3 deadline", content: "old", importance: 4)
        let out = Consolidator.merge(drafts: [draft("q3 deadline", "new", importance: 2)],
                                     into: [existing], summary: nil, source: "transcript")
        XCTAssertEqual(out.created, 0)
        XCTAssertEqual(out.updated, 1)
        XCTAssertEqual(out.memories.count, 1)
        XCTAssertEqual(out.memories.first?.content, "new")
        XCTAssertEqual(out.memories.first?.importance, 4)   // max(4, 2)
    }

    func testEntitiesUnionedAndSorted() {
        let existing = Memory(title: "People", content: "x", entities: ["Zoe"])
        let out = Consolidator.merge(drafts: [draft("People", entities: ["Anna", "Zoe"])],
                                     into: [existing], summary: nil, source: "transcript")
        XCTAssertEqual(out.memories.first?.entities, ["Anna", "Zoe"])
    }

    func testRelatedTitlesProduceBidirectionalLinks() {
        let out = Consolidator.merge(
            drafts: [draft("A", related: ["B"]), draft("B")],
            into: [], summary: nil, source: "transcript")
        let a = out.memories.first { $0.title == "A" }!
        let b = out.memories.first { $0.title == "B" }!
        XCTAssertTrue(a.links.contains(b.id))
        XCTAssertTrue(b.links.contains(a.id))   // bidirectional
    }

    func testSharedEntityLinksMemories() {
        let out = Consolidator.merge(
            drafts: [draft("A", entities: ["Sarah"]), draft("B", entities: ["Sarah"])],
            into: [], summary: nil, source: "transcript")
        let a = out.memories.first { $0.title == "A" }!
        let b = out.memories.first { $0.title == "B" }!
        XCTAssertTrue(a.links.contains(b.id))
        XCTAssertFalse(a.links.contains(a.id))  // never self-links
    }

    /// A small cluster (at the mesh limit) still fully connects: every member links to every other.
    func testSharedEntityAtMeshLimitIsFullMesh() {
        let k = Consolidator.entityLinkMeshLimit            // 6
        let drafts = (0..<k).map { draft("M\($0)", entities: ["Team"]) }
        let out = Consolidator.merge(drafts: drafts, into: [], summary: nil, source: "transcript")
        let entries = out.memories.reduce(0) { $0 + $1.links.count }
        XCTAssertEqual(entries, k * (k - 1))                // full mesh: k*(k-1) directed entries
        XCTAssertTrue(out.memories.allSatisfy { $0.links.count == k - 1 })  // every node degree k-1
    }

    /// A large shared-entity cluster stars instead of meshing, so links grow O(k) not O(k²) —
    /// the fix that keeps densely-interconnected graphs cheap to store and save.
    func testLargeSharedEntityClusterStarsInsteadOfMesh() {
        let k = 12                                          // well above the mesh limit
        let drafts = (0..<k).map { draft("M\($0)", entities: ["Team"]) }
        let out = Consolidator.merge(drafts: drafts, into: [], summary: nil, source: "transcript")
        let entries = out.memories.reduce(0) { $0 + $1.links.count }
        XCTAssertEqual(entries, 2 * (k - 1))                // star: k-1 undirected edges, both ways
        XCTAssertEqual(out.memories.filter { $0.links.count == k - 1 }.count, 1)  // exactly one hub
        XCTAssertTrue(out.memories.allSatisfy { !$0.links.contains($0.id) })      // never self-links
    }

    /// The star hub is stable across rounds: re-running the link pass adds no new links.
    func testStarHubIsStableAcrossRounds() {
        let k = 12
        let drafts = (0..<k).map { draft("M\($0)", entities: ["Team"]) }
        let first = Consolidator.merge(drafts: drafts, into: [], summary: nil, source: "transcript")
        // Feed the result back through another (empty-draft) round — relinking must be idempotent.
        let second = Consolidator.merge(drafts: [], into: first.memories, summary: nil, source: "transcript")
        let before = first.memories.reduce(0) { $0 + $1.links.count }
        let after = second.memories.reduce(0) { $0 + $1.links.count }
        XCTAssertEqual(after, before)
    }
}

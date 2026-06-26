import XCTest
@testable import Nemo

/// The graph view's layout is visual, but the edge set it draws is pure logic — explicit links
/// become strong edges, shared entities become weak ones, and every pair is emitted at most once.
final class MemoryGraphTests: XCTestCase {
    private func mem(_ title: String, links: [UUID] = [], entities: [String] = []) -> Memory {
        Memory(title: title, content: "", entities: entities, links: links)
    }

    func testExplicitLinksBecomeStrongEdges() {
        let a = mem("A")
        var b = mem("B")
        b.links = [a.id]
        let edges = graphEdges(for: [a, b])
        XCTAssertEqual(edges.count, 1)
        XCTAssertTrue(edges[0].strong)
        XCTAssertEqual(Set([edges[0].a, edges[0].b]), Set([a.id, b.id]))
    }

    func testSharedEntityBecomesWeakEdge() {
        let a = mem("A", entities: ["Priya"])
        let b = mem("B", entities: ["priya"])   // case-insensitive match
        let edges = graphEdges(for: [a, b])
        XCTAssertEqual(edges.count, 1)
        XCTAssertFalse(edges[0].strong)
    }

    func testExplicitLinkWinsOverSharedEntity() {
        let a = mem("A", entities: ["Edge"])
        var b = mem("B", entities: ["Edge"])
        b.links = [a.id]
        let edges = graphEdges(for: [a, b])
        XCTAssertEqual(edges.count, 1, "the pair should appear once, not as both strong and weak")
        XCTAssertTrue(edges[0].strong)
    }

    func testLinksToAbsentMemoriesAreDropped() {
        var a = mem("A")
        a.links = [UUID()]   // points at a memory not in the slice
        let edges = graphEdges(for: [a])
        XCTAssertTrue(edges.isEmpty)
    }

    func testLargeEntityClusterFallsBackToStar() {
        let people = (0..<10).map { mem("M\($0)", entities: ["Team"]) }
        let edges = graphEdges(for: people)
        // Star topology: n-1 edges rather than the n*(n-1)/2 of a full mesh.
        XCTAssertEqual(edges.count, people.count - 1)
        XCTAssertTrue(edges.allSatisfy { !$0.strong })
    }
}

import XCTest
@testable import Nemo

final class DedupeTests: XCTestCase {

    func testCandidatePairsByCosine() {
        let a = Memory(title: "Q3 deadline", content: "ends Sept 30")
        let b = Memory(title: "Quarterly deadline", content: "end of September")
        let c = Memory(title: "Lunch order", content: "pizza")
        let mems = [a, b, c]
        let pairs = Consolidator.candidatePairs(mems,
            cosine: { i, j in (Set([i, j]) == Set([0, 1])) ? 0.9 : 0.1 },
            cosineThreshold: 0.82)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.0, 0); XCTAssertEqual(pairs.first?.1, 1)
    }

    func testCandidatePairsJaccardFallbackWhenNoEmbeddings() {
        let a = Memory(title: "Acme contract renewal terms", content: "signed", entities: ["Acme"])
        let b = Memory(title: "Acme contract renewal terms", content: "signed", entities: ["Acme"])
        let c = Memory(title: "Totally other thing", content: "weather", entities: ["Sky"])
        let pairs = Consolidator.candidatePairs([a, b, c], cosine: { _, _ in nil }, cosineThreshold: 0.82)
        XCTAssertEqual(pairs.count, 1)   // a&b share entity + high jaccard; c unrelated
    }

    func testSemanticBlockingFindsDupWithoutSharedEntity() {
        // Three memories, no shared entities. Vectors put 0 and 1 near-parallel, 2 orthogonal.
        let a = Memory(title: "Q3 deadline", content: "ends Sept 30", entities: ["Q3"])
        let b = Memory(title: "Quarterly deadline", content: "end of September", entities: ["Quarter"])
        let c = Memory(title: "Lunch order", content: "pizza", entities: ["Food"])
        let vecs: [[Double]] = [[1, 0], [0.99, 0.141], [0, 1]]
        func dot(_ x: [Double], _ y: [Double]) -> Double { zip(x, y).map(*).reduce(0, +) }
        let pairs = Consolidator.candidatePairs([a, b, c],
            cosine: { i, j in dot(vecs[i], vecs[j]) },
            cosineThreshold: 0.82,
            vector: { vecs[$0] })                       // exercises the semantic-blocking path
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.0, 0); XCTAssertEqual(pairs.first?.1, 1)
    }

    func testCandidatePairsSkipsSuperseded() {
        var a = Memory(title: "Acme renewal", content: "signed", entities: ["Acme"])
        let b = Memory(title: "Acme renewal", content: "signed", entities: ["Acme"])
        a.superseded = true
        let pairs = Consolidator.candidatePairs([a, b], cosine: { _, _ in nil }, cosineThreshold: 0.82)
        XCTAssertTrue(pairs.isEmpty)                     // archived memory is never a candidate
    }

    func testApplyMergesFoldsAndRepointsLinks() {
        let keep = Memory(title: "Keep", content: "k", entities: ["X"], importance: 3)
        var drop = Memory(title: "Drop", content: "d", entities: ["Y"], importance: 5)
        drop.hitCount = 2
        var other = Memory(title: "Other", content: "o")
        other.links = [drop.id]   // points at the soon-to-be-dropped memory

        let action = Consolidator.MergeAction(keep: keep.id, drop: drop.id,
                                              title: "Merged", content: "merged body")
        let result = Consolidator.applyMerges([keep, drop, other], [action])

        XCTAssertEqual(result.count, 2)                       // drop removed
        let merged = result.first { $0.id == keep.id }!
        XCTAssertEqual(merged.title, "Merged")
        XCTAssertEqual(merged.entities, ["X", "Y"])           // unioned + sorted
        XCTAssertEqual(merged.importance, 5)                  // max
        XCTAssertEqual(merged.hitCount, 2)                    // summed
        let otherAfter = result.first { $0.id == other.id }!
        XCTAssertEqual(otherAfter.links, [keep.id])           // repointed drop → keep
    }

    func testApplyMergesSkipsMissingIds() {
        let a = Memory(title: "A", content: "a")
        let bogus = Consolidator.MergeAction(keep: a.id, drop: UUID(), title: "x", content: "y")
        XCTAssertEqual(Consolidator.applyMerges([a], [bogus]).count, 1)
    }
}

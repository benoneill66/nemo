import XCTest
@testable import Nemo

/// Pure-lifecycle tests for the dream pass (plan 17): promotion, the forgetting curve's
/// archive/demote transitions, purge-after-grace, and applying LLM triage verdicts. No LLM here.
final class DreamTests: XCTestCase {

    private func mem(_ title: String, category: Nemo.Category = .facts, importance: Int = 2,
                     hitCount: Int = 0, stage: MemoryStage = .episodic,
                     lastSurfacedDaysAgo: Double? = nil, now: Date) -> Memory {
        var m = Memory(title: title, content: "x", category: category.rawValue, importance: importance)
        m.hitCount = hitCount
        m.stage = stage
        m.retention = 1.0
        if let d = lastSurfacedDaysAgo { m.lastSurfaced = now.addingTimeInterval(-d * 86_400) }
        else { m.updated = now }   // fresh
        return m
    }

    private func lifecycle(_ ms: [Memory], now: Date, floor: Double = 0.15, grace: Int = 90) -> Dream.Lifecycle {
        Dream.runLifecycle(ms, now: now, episodicHalfLife: 10, semanticHalfLife: 30,
                           retentionFloor: floor, purgeGraceDays: grace, promoteHitCount: 3)
    }

    func testReinforcedEpisodicPromotesToSemantic() {
        let now = Date()
        let hot = mem("Hot", hitCount: 3, lastSurfacedDaysAgo: 0, now: now)
        let out = lifecycle([hot], now: now)
        XCTAssertEqual(out.memories[0].stage, .semantic)
        XCTAssertEqual(out.promoted, 1)
        XCTAssertEqual(out.memories[0].retention, Reinforcement.retentionMax, accuracy: 1e-9)
    }

    func testDurableCategoryPromotes() {
        let now = Date()
        let dec = mem("A decision", category: .decisions, lastSurfacedDaysAgo: 0, now: now)
        XCTAssertTrue(Dream.shouldPromote(dec, promoteHitCount: 3))
        XCTAssertEqual(lifecycle([dec], now: now).memories[0].stage, .semantic)
    }

    func testColdEpisodicArchivedBelowFloor() {
        let now = Date()
        let cold = mem("Stale dev note", category: .projects, lastSurfacedDaysAgo: 60, now: now)
        let out = lifecycle([cold], now: now)
        XCTAssertTrue(out.memories[0].superseded)
        XCTAssertNotNil(out.memories[0].archivedAt)
        XCTAssertEqual(out.archived, 1)
    }

    func testFreshEpisodicSurvives() {
        let now = Date()
        let fresh = mem("Just said", category: .projects, lastSurfacedDaysAgo: 0, now: now)
        let out = lifecycle([fresh], now: now)
        XCTAssertFalse(out.memories[0].superseded)
        XCTAssertEqual(out.archived, 0)
    }

    func testColdSemanticDemotedNotArchived() {
        let now = Date()
        // semantic, low importance/hits so promotion won't re-grab it, long unsurfaced.
        let cold = mem("Old durable fact", category: .facts, stage: .semantic,
                       lastSurfacedDaysAgo: 365, now: now)
        let out = lifecycle([cold], now: now)
        XCTAssertEqual(out.memories[0].stage, .episodic)   // demoted, gets another cycle
        XCTAssertFalse(out.memories[0].superseded)         // never archived outright
        XCTAssertEqual(out.demoted, 1)
        XCTAssertEqual(out.archived, 0)
    }

    func testPinnedNeverForgotten() {
        let now = Date()
        var pinned = mem("Pinned", category: .projects, lastSurfacedDaysAgo: 999, now: now)
        pinned.pinned = true
        let out = lifecycle([pinned], now: now)
        XCTAssertFalse(out.memories[0].superseded)
        XCTAssertEqual(out.memories[0].retention, Reinforcement.retentionMax, accuracy: 1e-9)
    }

    func testPurgeOnlyAfterGrace() {
        let now = Date()
        var old = mem("Long archived", now: now)
        old.superseded = true; old.archivedAt = now.addingTimeInterval(-100 * 86_400)
        var recent = mem("Recently archived", now: now)
        recent.superseded = true; recent.archivedAt = now.addingTimeInterval(-30 * 86_400)
        let out = lifecycle([old, recent], now: now, grace: 90)
        XCTAssertEqual(out.purged, 1)
        XCTAssertEqual(out.memories.count, 1)
        XCTAssertEqual(out.memories[0].title, "Recently archived")
    }

    func testPurgeScrubsDanglingLinks() {
        let now = Date()
        var doomed = mem("Doomed", now: now)
        doomed.superseded = true; doomed.archivedAt = now.addingTimeInterval(-200 * 86_400)
        var keeper = mem("Keeper", category: .decisions, lastSurfacedDaysAgo: 0, now: now)
        keeper.links = [doomed.id]
        let out = lifecycle([doomed, keeper], now: now)
        XCTAssertEqual(out.purged, 1)
        XCTAssertEqual(out.memories.count, 1)
        XCTAssertFalse(out.memories[0].links.contains(doomed.id))
    }

    func testApplyTriageRecategorizesAndArchives() {
        let now = Date()
        let a = mem("Move me", category: .projects, now: now)
        let b = mem("Forget me", category: .projects, now: now)
        let verdicts: [UUID: Dream.Verdict] = [
            a.id: .init(sid: "", action: "keep", category: "Decisions"),
            b.id: .init(sid: "", action: "archive", category: nil),
        ]
        let out = Dream.applyTriage([a, b], verdicts, now: now)
        XCTAssertEqual(out.recategorized, 1)
        XCTAssertEqual(out.archived, 1)
        XCTAssertEqual(out.memories.first { $0.id == a.id }?.category, Nemo.Category.decisions.rawValue)
        XCTAssertTrue(out.memories.first { $0.id == b.id }?.superseded ?? false)
    }

    func testApplyTriageSkipsUserEdited() {
        let now = Date()
        var edited = mem("Hands off", category: .projects, now: now)
        edited.userEdited = true
        let verdicts: [UUID: Dream.Verdict] = [edited.id: .init(sid: "", action: "archive", category: "Facts")]
        let out = Dream.applyTriage([edited], verdicts, now: now)
        XCTAssertEqual(out.recategorized, 0)
        XCTAssertEqual(out.archived, 0)
        XCTAssertFalse(out.memories[0].superseded)
        XCTAssertEqual(out.memories[0].category, Nemo.Category.projects.rawValue)
    }
}

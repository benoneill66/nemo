import XCTest
@testable import Nemo

final class ReinforcementTests: XCTestCase {

    func testReinforcedCapsAtCeiling() {
        var w = 0.0
        for _ in 0..<100 { w = Reinforcement.reinforced(w) }
        XCTAssertEqual(w, Reinforcement.cap, accuracy: 1e-9)
    }

    func testDecayHalvesOverOneHalfLife() {
        let now = Date()
        let ref = now.addingTimeInterval(-30 * 86_400)   // exactly one 30-day half-life ago
        XCTAssertEqual(Reinforcement.decayed(1.0, lastRef: ref, now: now, halfLifeDays: 30), 0.5, accuracy: 1e-6)
    }

    func testDecaySnapsTinyToZero() {
        let now = Date()
        let ref = now.addingTimeInterval(-300 * 86_400)   // many half-lives → ~0
        XCTAssertEqual(Reinforcement.decayed(1.0, lastRef: ref, now: now, halfLifeDays: 30), 0)
    }

    func testEffectiveImportanceOrdersAboveBase() {
        var hot = Memory(title: "Hot", content: "x", importance: 2)
        hot.weight = 1.5
        let cold = Memory(title: "Cold", content: "x", importance: 3)
        // base importance: cold(3) > hot(2); effective: hot(3.5) > cold(3)
        XCTAssertGreaterThan(hot.effectiveImportance, cold.effectiveImportance)
    }

    // MARK: - Forgetting curve (plan 17)

    func testRetainedHalvesOverEffectiveHalfLife() {
        let now = Date()
        // importance 0, no links → effective half-life == base.
        let ref = now.addingTimeInterval(-10 * 86_400)
        let r = Reinforcement.retained(1.0, lastRef: ref, now: now, halfLifeDays: 10,
                                       importance: 0, linkCount: 0)
        XCTAssertEqual(r, 0.5, accuracy: 1e-6)
    }

    func testImportanceAndLinksLengthenHalfLife() {
        let now = Date()
        let ref = now.addingTimeInterval(-10 * 86_400)
        let plain = Reinforcement.retained(1.0, lastRef: ref, now: now, halfLifeDays: 10,
                                           importance: 0, linkCount: 0)
        let sticky = Reinforcement.retained(1.0, lastRef: ref, now: now, halfLifeDays: 10,
                                            importance: 5, linkCount: 8)
        // A more important, better-connected memory decays slower → retains more after the same time.
        XCTAssertGreaterThan(sticky, plain)
    }

    func testRetainedSnapsTinyToZero() {
        let now = Date()
        let ref = now.addingTimeInterval(-1000 * 86_400)
        XCTAssertEqual(Reinforcement.retained(1.0, lastRef: ref, now: now, halfLifeDays: 10,
                                              importance: 0, linkCount: 0), 0)
    }

    func testBoostedCapsAtMax() {
        var r = 0.0
        for _ in 0..<100 { r = Reinforcement.boosted(r) }
        XCTAssertEqual(r, Reinforcement.retentionMax, accuracy: 1e-9)
    }

    func testMemoryDefaultsAreEpisodicAndFullyRetained() {
        let m = Memory(title: "New", content: "x")
        XCTAssertEqual(m.stage, .episodic)
        XCTAssertEqual(m.retention, 1.0, accuracy: 1e-9)
        XCTAssertNil(m.archivedAt)
    }
}

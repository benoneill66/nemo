import Foundation

/// Pure math for memory reinforcement & decay (plan 02). Kept separate from `AppState` so it's
/// unit-testable. `weight` is a learned signal added to a memory's base `importance` for ranking;
/// it grows when a memory keeps surfacing and decays when it doesn't.
enum Reinforcement {
    static let step = 0.15   // added each time a memory freshly surfaces
    static let cap = 2.0     // ceiling on learned weight

    /// New weight after a fresh surfacing, capped.
    static func reinforced(_ weight: Double) -> Double { min(cap, weight + step) }

    /// Exponentially-decayed weight given time since the memory was last relevant.
    /// Snaps tiny values to 0 so stale memories fully relax to their base importance.
    static func decayed(_ weight: Double, lastRef: Date, now: Date, halfLifeDays: Double) -> Double {
        guard weight > 0 else { return 0 }
        let days = now.timeIntervalSince(lastRef) / 86_400
        let d = weight * pow(0.5, days / max(1, halfLifeDays))
        return d < 0.01 ? 0 : d
    }

    // MARK: - Forgetting curve (plan 17)

    static let retentionMax = 1.0   // ceiling on retention strength
    static let retentionStep = 0.5  // added when a memory is surfaced (spaced repetition)

    /// Effective half-life for a memory's retention: important, well-connected memories are stickier,
    /// so they decay slower. Pure so the caller (and tests) can reason about it directly.
    static func effectiveHalfLife(base: Double, importance: Int, linkCount: Int) -> Double {
        base * (1 + 0.15 * Double(importance) + 0.05 * Double(min(linkCount, 10)))
    }

    /// Ebbinghaus forgetting curve for a memory's `retention`. Decays exponentially with time since
    /// it was last reinforced (surfaced / updated), with a half-life lengthened by importance and
    /// connectedness. Snaps tiny values to 0. Surfacing should reset `lastRef` and bump retention
    /// via `boosted(_:)` — spaced repetition.
    static func retained(_ retention: Double, lastRef: Date, now: Date,
                         halfLifeDays: Double, importance: Int, linkCount: Int) -> Double {
        guard retention > 0 else { return 0 }
        let hl = effectiveHalfLife(base: halfLifeDays, importance: importance, linkCount: linkCount)
        let days = max(0, now.timeIntervalSince(lastRef) / 86_400)
        let r = retention * pow(0.5, days / max(1, hl))
        return r < 0.01 ? 0 : r
    }

    /// Retention after a fresh surfacing, capped — spaced repetition pushes it back toward full.
    static func boosted(_ retention: Double) -> Double { min(retentionMax, retention + retentionStep) }
}

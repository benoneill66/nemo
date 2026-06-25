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
}

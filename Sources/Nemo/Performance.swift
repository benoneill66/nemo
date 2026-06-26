import SwiftUI

// MARK: - Audio meter

/// The live microphone level, kept in its own tiny observable so that the ~47 buffers/second
/// flowing off the audio tap invalidate *only* the waveform — not every view bound to
/// `AppState`. Before this existed, each buffer republished `AppState`, re-evaluating the whole
/// UI tree dozens of times a second the entire time Nemo was listening. The raw level is
/// smoothed here and the published value is coalesced to ~24 Hz, which is plenty for a meter.
@MainActor
final class AudioMeter: ObservableObject {
    /// Smoothed, display-ready level in 0…1. Read this from the waveform.
    @Published private(set) var level: Float = 0

    private var smoothed: Float = 0
    private var lastPublish = Date.distantPast
    private let minInterval: TimeInterval = 1.0 / 24.0

    /// Feed a raw per-buffer level. Smooths and throttles before touching `@Published`.
    func update(_ raw: Float) {
        smoothed = smoothed * 0.55 + raw * 0.45
        let now = Date()
        // Publish on a cadence, but let a large jump through immediately so onsets feel snappy.
        if now.timeIntervalSince(lastPublish) >= minInterval || abs(smoothed - level) > 0.12 {
            lastPublish = now
            level = smoothed
        }
    }

    /// Snap back to silence (stop / pause).
    func reset() {
        smoothed = 0
        level = 0
    }
}

// MARK: - Activity-gated timeline schedule

/// A `TimelineSchedule` that ticks at `activeFPS` while `isActive()` is true and drops to a slow
/// `idleInterval` keepalive otherwise. Animated views (the memory-graph physics, the overlay
/// waveform) use this so they stop redrawing the moment they settle, instead of pinning a core at
/// the display refresh rate forever. The keepalive ticks are how the view notices it should come
/// back to life after a reheat — within `idleInterval` of the change.
struct ActivitySchedule: TimelineSchedule {
    var activeFPS: Double = 60
    var idleInterval: TimeInterval = 0.25
    let isActive: () -> Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        return AnyIterator {
            let interval = isActive() ? 1.0 / activeFPS : idleInterval
            next = next.addingTimeInterval(interval)
            return next
        }
    }
}

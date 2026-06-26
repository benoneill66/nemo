import SwiftUI
import AppKit
import Combine

enum OverlayMetrics {
    static let cardWidth: CGFloat = 360
    static let margin: CGFloat = 8           // transparent breathing room around the card
    static var panelWidth: CGFloat { cardWidth + margin * 2 }
    static let minHeight: CGFloat = 60
    static let maxHeight: CGFloat = 280
}

/// Owns the persistent floating "listening" bar — a borderless, always-on-top panel that
/// follows you across Spaces (Wispr-style). It surfaces whenever Nemo is capturing audio,
/// shows a live waveform driven by the mic level, and *expands on its own* to reflect what
/// Nemo is doing right now: saving to memory, importing, or surfacing a relevant memory.
/// Tap to toggle listening, drag to reposition. Disabled with `"overlay": false`.
@MainActor
final class OverlayController {
    private let state: AppState
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []

    init(state: AppState) {
        self.state = state
        guard Config.overlayEnabled else { return }

        // Show/hide as listening flips (always shown if overlayAlwaysVisible). `dropFirst`
        // skips the synchronous initial emission — at construction time (during the App's
        // @StateObject init) the window server isn't ready to front a panel yet.
        state.$listening
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] on in self?.setVisible(on || Config.overlayAlwaysVisible) }
            .store(in: &cancellables)

        // Apply the initial visibility once the run loop is up and windows exist.
        DispatchQueue.main.async { [weak self] in
            self?.setVisible(state.listening || Config.overlayAlwaysVisible)
        }
    }

    // MARK: - Panel lifecycle

    private func setVisible(_ visible: Bool) {
        if visible {
            let panel = panel ?? makePanel()
            self.panel = panel
            positionBottomCenter(panel)
            panel.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let root = OverlayBar(onHeight: { [weak self] h in self?.resize(to: h) })
            .environmentObject(state)
        let hosting = NSHostingView(rootView: root)
        let initial = NSRect(x: 0, y: 0, width: OverlayMetrics.panelWidth, height: OverlayMetrics.minHeight)
        hosting.frame = initial
        hosting.autoresizingMask = [.width, .height]

        let panel = NSPanel(contentRect: initial,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                      // flat, shadowless HUD
        panel.isMovableByWindowBackground = true     // drag the bar to reposition it
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        return panel
    }

    private let bottomInset: CGFloat = 44

    /// Park the bar centered near the bottom of the active screen, like a system HUD.
    private func positionBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.midX - panel.frame.width / 2, y: vf.minY + bottomInset))
    }

    /// Grow/shrink the panel to fit the card, always re-pinning its bottom edge to the screen
    /// so it expands upward (the natural direction for a bottom-anchored HUD) and never slides
    /// off the bottom as it grows.
    private func resize(to rawHeight: CGFloat) {
        guard let panel else { return }
        let h = max(OverlayMetrics.minHeight, min(rawHeight, OverlayMetrics.maxHeight))
        guard abs(panel.frame.height - h) > 0.5 else { return }
        let vf = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        var f = panel.frame
        f.size.height = h
        if let vf { f.origin.y = vf.minY + bottomInset }   // keep the bottom edge on-screen
        panel.setFrame(f, display: true, animate: false)
    }
}

// MARK: - The bar

/// The floating pill: status orb, live waveform, a one-line preview of what Nemo is hearing,
/// and an expanding tray that reveals current activity (saving / importing / relevant memory).
struct OverlayBar: View {
    @EnvironmentObject var state: AppState
    var onHeight: (CGFloat) -> Void

    private var saving: Bool { state.isConsolidating || state.isImporting }
    private var topSurfaced: [SurfacedMemory] { Array(state.surfaced.prefix(2)) }
    private var hasTray: Bool { saving || !topSurfaced.isEmpty }
    private var idle: Bool { !state.listening }

    private var caption: String {
        if state.isImporting { return state.statusText }
        if state.isConsolidating { return "Saving to memory" }
        if !state.partialText.isEmpty { return state.partialText }
        return state.statusText
    }

    var body: some View {
        card
            .padding(OverlayMetrics.margin)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: OverlayMetrics.panelWidth)
            .background(GeometryReader { g in
                Color.clear.preference(key: HeightKey.self, value: g.size.height)
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onPreferenceChange(HeightKey.self) { onHeight($0) }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: hasTray)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: topSurfaced.map(\.id))
    }

    private var card: some View {
        // Tray sits *above* the header so the persistent bar stays pinned to the bottom of
        // the screen and new information rises above it (the panel grows upward).
        VStack(spacing: 0) {
            if hasTray {
                tray.padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 9)
                Divider().overlay(.white.opacity(0.12)).padding(.horizontal, 14)
            }
            header
        }
        .frame(width: OverlayMetrics.cardWidth, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
        )
        .preferredColorScheme(.dark)
    }

    // MARK: Header (always visible)

    private var header: some View {
        HStack(spacing: 10) {
            ListeningOrb(active: state.listening)
            WaveBars(level: state.audioLevel, active: state.listening)
                .frame(width: 56)
            Text(caption)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(idle ? 0.55 : 0.92))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture { state.toggleListening() }
        .help(state.listening ? "Nemo is listening — click to stop" : "Click to start listening")
    }

    @ViewBuilder private var trailing: some View {
        if saving {
            ProgressView().controlSize(.small).tint(.white)
        } else if !topSurfaced.isEmpty {
            GlassPill(text: "\(state.surfaced.count)", systemImage: "sparkles")
        } else {
            Image(systemName: state.listening ? "stop.fill" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: Tray (expands on activity)

    @ViewBuilder private var tray: some View {
        if saving {
            HStack(spacing: 8) {
                Image(systemName: state.isImporting ? "square.and.arrow.down.fill" : "brain.head.profile")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text(state.isImporting ? "Updating memory from import…" : "Distilling what you said into memory…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 9, weight: .bold))
                    Text("Relevant now").font(.system(size: 9.5, weight: .bold))
                        .textCase(.uppercase).tracking(0.6)
                }
                .foregroundStyle(.white.opacity(0.5))
                ForEach(topSurfaced) { SurfacedRow(item: $0) }
            }
        }
    }

    private var background: some View {
        VisualEffectView(material: .hudWindow)
    }
}

/// One "relevant now" line: category-tinted icon + memory title.
private struct SurfacedRow: View {
    let item: SurfacedMemory
    var body: some View {
        let cat = item.memory.categoryEnum
        HStack(spacing: 9) {
            Image(systemName: cat.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hue: cat.hue, saturation: 0.7, brightness: 1))
                .frame(width: 16)
            Text(item.memory.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color(hue: cat.hue, saturation: 0.7, brightness: 1).opacity(0.12)))
    }
}

/// Five capsule bars that breathe with the live mic level; gently idles when paused.
private struct WaveBars: View {
    let level: Float
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(active ? Color.green.opacity(0.95) : Color.white.opacity(0.3))
                        .frame(width: 3.5, height: height(i, t))
                }
            }
            .frame(height: 26, alignment: .center)
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }

    private func height(_ i: Int, _ t: Double) -> CGFloat {
        let phase = Double(i) * 0.7
        let wobble = (sin(t * 7 + phase) + 1) / 2          // 0…1
        let amp = active ? Double(level) : 0.05
        let h = 4 + amp * 22 * (0.35 + 0.65 * wobble)
        return max(4, CGFloat(h))
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = OverlayMetrics.minHeight
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

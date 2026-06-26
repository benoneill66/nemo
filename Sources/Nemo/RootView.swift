import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case live = "Live", memory = "Memory", sessions = "Sessions", importing = "Import", activity = "Activity"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .live: return "waveform"
        case .memory: return "brain.head.profile"
        case .sessions: return "calendar"
        case .importing: return "square.and.arrow.down.on.square"
        case .activity: return "chart.bar.fill"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var tab: Tab = .live

    var body: some View {
        ZStack {
            AuroraBackground()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 232)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(16)
        }
        .frame(minWidth: 940, minHeight: 600)
        .background(VisualEffectView(material: .underPageBackground))
        .preferredColorScheme(.dark)
        .tint(.white)
        // Capture the window-opening action so the floating overlay can reopen/raise
        // the main window from outside the scene graph. Stays valid for the app's lifetime.
        .onAppear { state.openMainWindow = { openWindow(id: "main") } }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ListeningOrb(active: state.listening)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nemo").font(.system(size: 17, weight: .bold))
                    Text("always listening").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.bottom, 2)

            GlassButton(title: state.listening ? "Stop Listening" : "Start Listening",
                        systemImage: state.listening ? "stop.fill" : "mic.fill",
                        prominent: !state.listening) { state.toggleListening() }

            GlassButton(title: state.inMeeting ? "End Meeting" : "Start Meeting",
                        systemImage: state.inMeeting ? "person.3.fill" : "person.3") {
                state.inMeeting ? state.endMeeting() : state.startMeeting(title: nil)
            }

            PauseControl()

            VStack(spacing: 4) {
                ForEach(Tab.allCases) { t in
                    NavRow(tab: t, selected: tab == t,
                           badge: t == .memory ? state.memories.count : nil) { tab = t }
                }
            }
            .padding(.top, 6)

            Spacer()

            StatusFooter()
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(cornerRadius: 22, strong: true)
        .padding(.trailing, 16)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .live: LivePane()
        case .memory: MemoryPane()
        case .sessions: SessionsPane()
        case .importing: ImportPane()
        case .activity: ActivityPane()
        }
    }
}

// MARK: - Sidebar pieces

private struct NavRow: View {
    let tab: Tab
    let selected: Bool
    var badge: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol).frame(width: 20)
                Text(tab.rawValue).font(.system(size: 13, weight: .medium))
                Spacer()
                if let badge, badge > 0 {
                    Text("\(badge)").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.16) : .clear)
            )
            .foregroundStyle(.white.opacity(selected ? 1 : 0.72))
        }
        .buttonStyle(.plain)
    }
}

/// Timed private-mode pause (plan 06): a quick menu of durations, or resume when paused.
struct PauseControl: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.isPaused {
            GlassButton(title: resumeTitle, systemImage: "play.fill") { state.resumeFromPause() }
        } else if state.listening {
            Menu {
                Button("Pause 15 minutes") { state.pause(for: 15 * 60) }
                Button("Pause 1 hour") { state.pause(for: 60 * 60) }
                Button("Pause until I resume") { state.pause(for: 8 * 60 * 60) }
            } label: {
                Label("Pause", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .menuStyle(.borderlessButton)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var resumeTitle: String {
        if let until = state.pausedUntil {
            let mins = max(0, Int(until.timeIntervalSinceNow / 60))
            return "Resume (paused \(mins)m left)"
        }
        return "Resume"
    }
}

/// A pulsing orb that reflects whether the mic is live.
struct ListeningOrb: View {
    let active: Bool
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle().fill(active ? Color.green.opacity(0.85) : Color.gray.opacity(0.6))
                .frame(width: 14, height: 14)
            if active {
                Circle().stroke(Color.green.opacity(0.5), lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 0.8)
            }
        }
        .frame(width: 30, height: 30)
        .onAppear { if active { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } } }
        .onChange(of: active) { on in
            pulse = false
            if on { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
        }
    }
}

struct StatusFooter: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let health = state.assistantHealth {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(health.localizedDescription)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.18)))
            }
            if state.isConsolidating || state.isImporting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(state.isImporting ? "Importing…" : "Consolidating…")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                }
            }
            Text(state.statusText)
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                GlassPill(text: "\(state.memories.count) memories", systemImage: "brain")
                if state.unconsolidatedCount > 0 {
                    GlassPill(text: "\(state.unconsolidatedCount) pending", systemImage: "clock")
                }
            }
            GlassPill(text: state.engineName, systemImage: "waveform.badge.mic", hue: 0.4)
        }
    }
}

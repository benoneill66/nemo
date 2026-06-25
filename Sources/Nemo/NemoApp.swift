import SwiftUI
import AppKit

@main
struct NemoApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Nemo", id: "main") {
            RootView()
                .environmentObject(state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(state.listening ? "Stop Listening" : "Start Listening") { state.toggleListening() }
                    .keyboardShortcut("l", modifiers: [.command])
            }
        }

        MenuBarExtra("Nemo", systemImage: "ear") {
            MenuBarControl().environmentObject(state)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Compact glass control surfaced from the menu bar.
struct MenuBarControl: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ListeningOrb(active: state.listening)
                Text("Nemo").font(.system(size: 14, weight: .bold))
            }
            Text(state.statusText).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            if !state.partialText.isEmpty {
                Text(state.partialText).font(.system(size: 11)).italic()
                    .foregroundStyle(.white.opacity(0.6)).lineLimit(2)
            }

            Divider().overlay(.white.opacity(0.15))

            GlassButton(title: state.listening ? "Stop Listening" : "Start Listening",
                        systemImage: state.listening ? "stop.fill" : "mic.fill",
                        prominent: !state.listening) { state.toggleListening() }
            GlassButton(title: state.inMeeting ? "End Meeting" : "Start Meeting",
                        systemImage: "person.3") {
                state.inMeeting ? state.endMeeting() : state.startMeeting(title: nil)
            }
            GlassButton(title: "Open Nemo", systemImage: "macwindow") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }

            HStack {
                GlassPill(text: "\(state.memories.count) memories", systemImage: "brain")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(VisualEffectView(material: .hudWindow))
        .preferredColorScheme(.dark)
        .tint(.white)
    }
}

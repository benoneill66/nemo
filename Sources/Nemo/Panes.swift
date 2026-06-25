import SwiftUI

// MARK: - Shared header

private struct PaneHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private let timeFmt: DateFormatter = {
    let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .medium; return f
}()

// MARK: - Live transcription

struct LivePane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                PaneHeader(title: "Live", subtitle: "Everything Nemo is hearing, transcribed on-device.")
                GlassButton(title: "Consolidate Now", systemImage: "wand.and.stars") { state.consolidateNow() }
                    .frame(width: 190)
            }

            // Today's morning briefing — open items + recent sessions, distilled on launch.
            if state.isBriefing && state.briefing == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing your briefing…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14).glassCard(cornerRadius: 16, tintHue: 0.13)
            } else if let b = state.briefing, !state.briefingDismissed {
                BriefingCard(briefing: b)
            }

            // What's being heard right now.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(.green)
                    Text(state.listening ? "Hearing now" : "Not listening")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                }
                Text(state.partialText.isEmpty ? "…" : state.partialText)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(state.partialText.isEmpty ? 0.3 : 0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .glassCard(tintHue: 0.4)

            // Memories relevant to what's being said right now — surfaced automatically.
            if !state.surfaced.isEmpty {
                RelevantNowStrip()
            }

            if let answer = state.lastAnswer {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill").foregroundStyle(.cyan)
                    Text(answer).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                }
                .padding(12).glassCard(cornerRadius: 14, tintHue: 0.55)
            }

            // Speakers picked out of the conversation — tap any to give them a real name.
            if !state.activeSpeakers.isEmpty {
                SpeakersStrip()
            }

            // Recent transcript.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(state.segments.reversed()) { seg in
                        SegmentRow(seg: seg) { state.toggleMark(seg.id) }
                    }
                    if state.segments.isEmpty {
                        Text("Press Start Listening — transcribed speech will stream in here.")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                            .padding(.top, 40)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(20)
        .glassCard(cornerRadius: 22)
    }
}

private struct SegmentRow: View {
    @EnvironmentObject var state: AppState
    let seg: TranscriptSegment
    let toggle: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timeFmt.string(from: seg.start))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if let sp = state.speaker(seg.speaker) {
                    SpeakerTag(name: sp.name, hue: sp.hue)
                }
                Text(seg.text)
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: toggle) {
                Image(systemName: seg.marked ? "star.fill" : "star")
                    .foregroundStyle(seg.marked ? .yellow : .white.opacity(0.35))
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(seg.marked ? Color.yellow.opacity(0.1) : Color.white.opacity(0.04)))
    }
}

/// A small colored dot + name shown beside a transcript line to mark who spoke it.
private struct SpeakerTag: View {
    let name: String
    let hue: Double
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color(hue: hue, saturation: 0.7, brightness: 1))
                .frame(width: 6, height: 6)
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(hue: hue, saturation: 0.55, brightness: 1).opacity(0.95))
        }
    }
}

// MARK: - Speakers (diarization)

/// The distinct voices Nemo has separated out of the conversation. Each is a pill the user can
/// tap to rename (e.g. "Speaker 2" → "Priya"); the name then flows through the transcript and
/// into how memories are attributed.
private struct SpeakersStrip: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.wave.2.fill").foregroundStyle(.mint)
                Text("Speakers")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Text("identified on-device · tap to name")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(state.activeSpeakers) { sp in
                        SpeakerRenamePill(speaker: sp)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 16, tintHue: 0.45)
    }
}

private struct SpeakerRenamePill: View {
    @EnvironmentObject var state: AppState
    let speaker: SpeakerIdentity
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Button { draft = speaker.renamed ? speaker.name : ""; editing = true } label: {
            HStack(spacing: 5) {
                Circle().fill(Color(hue: speaker.hue, saturation: 0.7, brightness: 1))
                    .frame(width: 8, height: 8)
                Text(speaker.name).font(.system(size: 12, weight: .medium))
                Image(systemName: "pencil").font(.system(size: 9)).opacity(0.5)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color(hue: speaker.hue, saturation: 0.7, brightness: 1).opacity(0.18)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .foregroundStyle(.white.opacity(0.92))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Name this speaker").font(.system(size: 12, weight: .semibold))
                TextField("e.g. Priya", text: $draft)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit { commit() }
                HStack {
                    Button("Clear") { state.renameSpeaker(speaker.id, to: ""); editing = false }
                        .controlSize(.small)
                    Spacer()
                    Button("Save") { commit() }.controlSize(.small).keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 230)
        }
    }

    private func commit() {
        state.renameSpeaker(speaker.id, to: draft)
        editing = false
    }
}

// MARK: - Morning briefing

private struct BriefingCard: View {
    @EnvironmentObject var state: AppState
    let briefing: Briefing
    private var speaking: Bool { state.speakingBriefing }

    private var stamp: String {
        let f = DateFormatter()
        f.dateStyle = Calendar.current.isDateInToday(briefing.generated) ? .none : .medium
        f.timeStyle = .short
        let when = f.string(from: briefing.generated)
        return Calendar.current.isDateInToday(briefing.generated) ? "this morning · \(when)" : when
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sun.horizon.fill").foregroundStyle(.orange)
                Text("Morning briefing")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(stamp).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button { toggleSpeak() } label: {
                    Image(systemName: speaking ? "stop.circle.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(.white.opacity(0.7))
                }.buttonStyle(.plain).help(speaking ? "Stop" : "Read aloud")
                Button { state.generateBriefing() } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.white.opacity(0.7))
                }.buttonStyle(.plain).disabled(state.isBriefing).help("Regenerate")
                Button { state.dismissBriefing() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5))
                }.buttonStyle(.plain).help("Dismiss")
            }
            Text(briefing.text)
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .glassCard(cornerRadius: 16, tintHue: 0.11)
        .onDisappear { if speaking { state.stopSpeaking() } }
    }

    private func toggleSpeak() {
        if speaking { state.stopSpeaking() } else { state.speakBriefing() }
    }
}

// MARK: - Relevant now (live surfacing)

/// A horizontal strip of memories the relevance engine surfaced for the current moment.
private struct RelevantNowStrip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.cyan)
                Text("Relevant now")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Text("surfaced as you speak")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(state.surfaced) { item in
                        SurfacedCard(item: item) { state.dismissSurfaced(item.id) }
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 16, tintHue: 0.55)
        .animation(.easeInOut(duration: 0.35), value: state.surfaced.map(\.id))
    }
}

private struct SurfacedCard: View {
    let item: SurfacedMemory
    let dismiss: () -> Void
    private var mem: Memory { item.memory }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: mem.categoryEnum.symbol).font(.system(size: 10))
                    .foregroundStyle(Color(hue: mem.categoryEnum.hue, saturation: 0.6, brightness: 1))
                Text(mem.category).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 6)
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }.buttonStyle(.plain)
            }
            Text(mem.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(mem.content).font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.forward").font(.system(size: 8))
                Text(item.reason).font(.system(size: 9, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.cyan.opacity(0.85))
        }
        .padding(11)
        .frame(width: 210, height: 132, alignment: .topLeading)
        .glassCard(cornerRadius: 14, tintHue: mem.categoryEnum.hue)
    }
}

// MARK: - Memory

struct MemoryPane: View {
    @EnvironmentObject var state: AppState
    @State private var filter: Category? = nil
    @State private var selected: Memory?

    private var shown: [Memory] {
        let base = filter.map { state.memories(in: $0) } ?? state.memories
        return base.sorted { $0.effectiveImportance != $1.effectiveImportance
            ? $0.effectiveImportance > $1.effectiveImportance : $0.updated > $1.updated }
    }
    private let cols = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)]

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                PaneHeader(title: "Memory", subtitle: "A rich, interconnected map of what Nemo knows about you.")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        CategoryChip(label: "All", symbol: "circle.grid.2x2", count: state.memories.count,
                                     selected: filter == nil) { filter = nil }
                        ForEach(Category.allCases, id: \.self) { cat in
                            let n = state.memories(in: cat).count
                            if n > 0 {
                                CategoryChip(label: cat.rawValue, symbol: cat.symbol, count: n,
                                             hue: cat.hue, selected: filter == cat) { filter = cat }
                            }
                        }
                    }
                }

                if state.memories.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
                            ForEach(shown) { mem in
                                MemoryCard(mem: mem, selected: selected?.id == mem.id) { selected = mem }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .glassCard(cornerRadius: 22)

            if let sel = selected, let live = state.memory(sel.id) {
                MemoryDetail(mem: live) { selected = nil }
                    .frame(width: 320)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain.head.profile").font(.system(size: 40)).foregroundStyle(.white.opacity(0.4))
            Text("No memories yet").font(.system(size: 15, weight: .semibold))
            Text("Start listening and Nemo will distill what it hears, or import what another assistant already knows from the Import tab.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CategoryChip: View {
    let label: String
    let symbol: String
    let count: Int
    var hue: Double? = nil
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(label).font(.system(size: 12, weight: .medium))
                Text("\(count)").font(.system(size: 10, weight: .bold)).opacity(0.6)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(selected ? Color(hue: hue ?? 0.6, saturation: 0.7, brightness: 1).opacity(0.3) : Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0.4 : 0.12), lineWidth: 0.5))
            .foregroundStyle(.white.opacity(selected ? 1 : 0.75))
        }.buttonStyle(.plain)
    }
}

private struct MemoryCard: View {
    let mem: Memory
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: mem.categoryEnum.symbol).font(.system(size: 11))
                        .foregroundStyle(Color(hue: mem.categoryEnum.hue, saturation: 0.6, brightness: 1))
                    Text(mem.category).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    if mem.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.yellow.opacity(0.85)) }
                    ImportanceDots(level: mem.importance)
                }
                Text(mem.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(mem.content).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                if !mem.entities.isEmpty || !mem.links.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(mem.entities.prefix(2), id: \.self) { GlassPill(text: $0, hue: mem.categoryEnum.hue) }
                        if mem.links.count > 0 { GlassPill(text: "\(mem.links.count)", systemImage: "link") }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 16, tintHue: mem.categoryEnum.hue)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(selected ? 0.6 : 0), lineWidth: 1.5))
        }.buttonStyle(.plain)
    }
}

private struct ImportanceDots: View {
    let level: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Circle().fill(i < level ? Color.yellow.opacity(0.9) : Color.white.opacity(0.18))
                    .frame(width: 5, height: 5)
            }
        }
    }
}

private struct MemoryDetail: View {
    @EnvironmentObject var state: AppState
    let mem: Memory
    let close: () -> Void

    @State private var editing = false
    @State private var draftTitle = ""
    @State private var draftContent = ""
    @State private var draftCategory = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if editing { editor } else { reader }

                if !mem.entities.isEmpty {
                    label("Entities")
                    FlowPills(items: mem.entities, hue: mem.categoryEnum.hue)
                }

                let related = mem.links.compactMap { state.memory($0) }
                if !related.isEmpty {
                    label("Connected to")
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(related) { r in
                            HStack(spacing: 6) {
                                Image(systemName: r.categoryEnum.symbol).font(.system(size: 10))
                                    .foregroundStyle(Color(hue: r.categoryEnum.hue, saturation: 0.6, brightness: 1))
                                Text(r.title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                sourceSection

                footer
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glassCard(cornerRadius: 22, tintHue: mem.categoryEnum.hue, strong: true)
    }

    // MARK: Header (category + pin + close)

    private var header: some View {
        HStack {
            if editing {
                Picker("", selection: $draftCategory) {
                    ForEach(Category.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 150)
            } else {
                GlassPill(text: mem.category, systemImage: mem.categoryEnum.symbol, hue: mem.categoryEnum.hue)
            }
            Spacer()
            Button { state.setPinned(mem.id, !mem.pinned) } label: {
                Image(systemName: mem.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(mem.pinned ? .yellow : .white.opacity(0.5))
            }.buttonStyle(.plain).help(mem.pinned ? "Unpin" : "Pin (protect from automation)")
            Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }
                .buttonStyle(.plain)
        }
    }

    // MARK: Read vs edit body

    private var reader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(mem.title).font(.system(size: 18, weight: .bold))
                if mem.userEdited {
                    Image(systemName: "pencil.circle.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
            }
            Text(mem.content).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Text("Importance").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                ImportanceDots(level: mem.importance)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $draftTitle).textFieldStyle(.roundedBorder)
            TextEditor(text: $draftContent)
                .font(.system(size: 13)).frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
            HStack(spacing: 8) {
                Text("Importance").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                Stepper(value: Binding(get: { mem.importance },
                                       set: { state.setImportance(mem.id, $0) }),
                        in: 1...5) { ImportanceDots(level: mem.importance) }
                    .labelsHidden()
            }
        }
    }

    // MARK: Provenance

    @ViewBuilder private var sourceSection: some View {
        let sources = state.sourceSegments(for: mem.id)
        if !sources.isEmpty {
            label("Source")
            VStack(alignment: .leading, spacing: 5) {
                ForEach(sources) { seg in
                    HStack(alignment: .top, spacing: 6) {
                        Text(timeFmt.string(from: seg.start))
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                            .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            if let name = state.speakerName(seg.speaker) {
                                Text(name).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                            }
                            Text(seg.text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }
        } else if !mem.sourceSegmentIds.isEmpty {
            label("Source")
            Text("Original speech is no longer retained.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: Footer (edit / save / delete)

    private var footer: some View {
        HStack(spacing: 10) {
            GlassPill(text: mem.source, systemImage: "antenna.radiowaves.left.and.right")
            Spacer()
            if editing {
                Button("Save") {
                    state.updateMemory(mem.id, title: draftTitle, content: draftContent, category: draftCategory)
                    editing = false
                }.controlSize(.small).keyboardShortcut(.defaultAction)
                Button("Cancel") { editing = false }.controlSize(.small)
            } else {
                Button { beginEditing() } label: {
                    Image(systemName: "pencil").foregroundStyle(.white.opacity(0.8))
                }.buttonStyle(.plain).help("Edit")
                Button(action: { state.deleteMemory(mem.id); close() }) {
                    Image(systemName: "trash").foregroundStyle(.red.opacity(0.8))
                }.buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    private func beginEditing() {
        draftTitle = mem.title
        draftContent = mem.content
        draftCategory = mem.categoryEnum.rawValue
        editing = true
    }

    private func label(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.45)).padding(.top, 4)
    }
}

/// Simple wrapping row of pills.
struct FlowPills: View {
    let items: [String]
    var hue: Double? = nil
    var body: some View {
        let rows = items.chunked(4)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) { ForEach(row, id: \.self) { GlassPill(text: $0, hue: hue) } }
            }
        }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// MARK: - Sessions

struct SessionsPane: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Sessions", subtitle: "Meetings and daily ambient capture, neatly organized.")
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(state.sessions.sorted { $0.start > $1.start }) { s in
                        SessionCard(session: s, count: state.segments(in: s).count)
                    }
                    if state.sessions.isEmpty {
                        Text("Start listening to begin a daily session, or start a meeting to capture one.")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).padding(.top, 40)
                    }
                }
            }
        }
        .padding(20).glassCard(cornerRadius: 22)
    }
}

private struct SessionCard: View {
    @EnvironmentObject var state: AppState
    let session: Session
    let count: Int
    @State private var expanded = false

    private var range: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        let start = f.string(from: session.start)
        if let end = session.end { let t = DateFormatter(); t.timeStyle = .short; return "\(start) – \(t.string(from: end))" }
        return "\(start) · ongoing"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: session.kind == .meeting ? "person.3.fill" : "sun.max.fill")
                    .foregroundStyle(session.kind == .meeting ? .orange : .yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 15, weight: .semibold))
                    Text(range).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                if session.isOpen { GlassPill(text: "live", systemImage: "dot.radiowaves.left.and.right", hue: 0.33) }
                GlassPill(text: "\(count)", systemImage: "text.alignleft")
                Button { withAnimation { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundStyle(.white.opacity(0.5))
                }.buttonStyle(.plain)
            }
            if let summary = session.summary {
                Text(summary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.78))
            }
            if expanded {
                Divider().overlay(.white.opacity(0.1))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(state.segments(in: session).suffix(40)) { seg in
                        HStack(alignment: .top, spacing: 8) {
                            if seg.marked { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow) }
                            if let sp = state.speaker(seg.speaker) {
                                Text(sp.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color(hue: sp.hue, saturation: 0.55, brightness: 1))
                                    .fixedSize()
                            }
                            Text(seg.text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 16, tintHue: session.kind == .meeting ? 0.08 : 0.14)
    }
}

// MARK: - Activity (LLM usage & cost — plan 09)

struct ActivityPane: View {
    @EnvironmentObject var state: AppState

    private var today: UsageRollup { state.usageRollup(days: 1) }
    private var week: UsageRollup { state.usageRollup(days: 7) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: "Activity", subtitle: "What Nemo's background AI is doing — metadata only, on-device.")

            HStack(spacing: 12) {
                RollupCard(title: "Today", rollup: today)
                RollupCard(title: "Last 7 days", rollup: week)
            }

            if let rate = week.gateDropRate {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.green)
                    Text("Relevance gate dropped \(Int(rate * 100))% of segments")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    Text("(\(week.gateKept) kept · \(week.gateDropped) dropped, saving expensive calls)")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 14, tintHue: 0.4)
            }

            if !week.byFeature.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("BY FEATURE · 7 DAYS").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                    ForEach(week.byFeature.sorted { $0.value > $1.value }, id: \.key) { feat, n in
                        HStack {
                            Text(feat.capitalized).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                            Spacer()
                            Text("\(n) call\(n == 1 ? "" : "s")").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .padding(14).glassCard(cornerRadius: 16, tintHue: 0.6)
            }

            recentList
        }
        .padding(20).glassCard(cornerRadius: 22)
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT CALLS").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.45))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(state.usage.filter(\.isCall).suffix(60).reversed()) { e in
                        HStack(spacing: 8) {
                            Circle().fill(e.outcome == "ok" ? Color.green.opacity(0.8) : Color.orange.opacity(0.9))
                                .frame(width: 6, height: 6)
                            Text(timeFmt.string(from: e.at)).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4)).frame(width: 78, alignment: .leading)
                            Text(e.feature).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                                .frame(width: 90, alignment: .leading)
                            Text("\(e.durationMs) ms").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                            Spacer()
                            if let i = e.inputTokens, let o = e.outputTokens {
                                Text("\(i)↓ \(o)↑\(e.estimated ? " est" : "")")
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .padding(.vertical, 3).padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.04)))
                    }
                    if state.usage.filter(\.isCall).isEmpty {
                        Text("No AI activity yet. Memories consolidate as you talk.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).padding(.top, 20)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct RollupCard: View {
    let title: String
    let rollup: UsageRollup

    private func fmt(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            Text("\(rollup.calls)").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
            Text("call\(rollup.calls == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            Divider().overlay(.white.opacity(0.1))
            stat("Tokens", "\(fmt(rollup.inputTokens))↓ \(fmt(rollup.outputTokens))↑")
            stat("Est. cost", String(format: "$%.3f%@", rollup.estimatedCost, rollup.anyEstimated ? " est" : ""))
            if rollup.failureRate > 0 {
                stat("Failures", "\(Int(rollup.failureRate * 100))%")
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16, tintHue: 0.13)
    }

    private func stat(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(v).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - Import

struct ImportPane: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                PaneHeader(title: "Import Context", subtitle: "Seed memory with what other AI assistants already know about you.")
                GlassButton(title: "Rescan", systemImage: "arrow.clockwise") { state.refreshImportSources() }
                    .frame(width: 130)
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(state.importSources) { src in
                        HStack(spacing: 12) {
                            Image(systemName: src.assistant == "claude" ? "sparkle" : "doc.text")
                                .font(.system(size: 20)).foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(src.label).font(.system(size: 14, weight: .semibold))
                                Text("\(src.fileCount) file\(src.fileCount == 1 ? "" : "s") · \(src.path)")
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            GlassButton(title: "Import", systemImage: "square.and.arrow.down") {
                                state.importContext(src)
                            }.frame(width: 120).disabled(state.isImporting)
                        }
                        .padding(14).glassCard(cornerRadius: 16, tintHue: 0.8)
                    }
                    if state.importSources.isEmpty {
                        Text("No assistant memories found. Add paths via \"importPaths\" in ~/.config/nemo/config.json, then Rescan.")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).padding(.top, 40)
                    }
                }
            }
        }
        .padding(20).glassCard(cornerRadius: 22)
    }
}

import Foundation
import SwiftUI

/// The brain of the always-listening assistant. Owns the transcription engine, applies
/// keyword marking + session routing to each segment, persists everything, periodically
/// consolidates transcripts into memory, imports outside context, and (optionally) answers
/// spoken "hey Nemo" questions aloud.
@MainActor
final class AppState: ObservableObject {
    // Persisted data
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var memories: [Memory] = []
    @Published private(set) var sessions: [Session] = []

    // Live UI state
    @Published private(set) var listening = false
    @Published private(set) var statusText = "Idle"
    @Published private(set) var partialText = ""           // what's being heard right now
    @Published private(set) var isConsolidating = false
    @Published private(set) var isImporting = false
    @Published private(set) var lastAnswer: String?        // last spoken "hey Nemo" reply
    @Published private(set) var importSources: [ContextImporter.Source] = []

    private let engine: SpeechEngine = makeSpeechEngine()
    private let speaker = Speaker()

    /// Which transcription backend is active (shown in the UI).
    var engineName: String { engine.displayName }

    private var consolidateTimer: Timer?
    private var answering = false

    private let wakePrefixes = ["hey ", "hey, ", "okay ", "ok ", "hi ", "yo "]

    init() {
        Store.migrateLegacyConfigIfNeeded()
        segments = Store.loadSegments()
        memories = Store.loadMemories()
        sessions = Store.loadSessions()
        refreshImportSources()   // walks ~/.claude off the main thread

        engine.onStatus = { [weak self] s in self?.handleStatus(s) }
        engine.onPartial = { [weak self] t in self?.partialText = t }
        engine.onSegment = { [weak self] text, start, end in
            self?.ingest(text: text, start: start, end: end)
        }
    }

    // MARK: - Derived

    var currentSession: Session? {
        sessions.first { $0.kind == .meeting && $0.isOpen } ?? sessions.first { $0.isOpen }
    }
    var inMeeting: Bool { sessions.contains { $0.kind == .meeting && $0.isOpen } }
    var unconsolidatedCount: Int { segments.filter { !$0.consolidated }.count }
    var markedSegments: [TranscriptSegment] { segments.filter { $0.marked } }

    func memories(in category: Category) -> [Memory] {
        memories.filter { $0.categoryEnum == category }
            .sorted { $0.importance != $1.importance ? $0.importance > $1.importance : $0.updated > $1.updated }
    }
    func memory(_ id: UUID) -> Memory? { memories.first { $0.id == id } }
    func segments(in session: Session) -> [TranscriptSegment] {
        segments.filter { $0.sessionId == session.id }
    }

    // MARK: - Listening control

    func toggleListening() { listening ? stop() : start() }

    func start() {
        ensureAmbientSession()
        engine.start()
        startConsolidateTimer()
    }

    func stop() {
        engine.stop()
        consolidateTimer?.invalidate(); consolidateTimer = nil
        listening = false
        partialText = ""
        statusText = "Paused"
    }

    private func handleStatus(_ s: SpeechEngineStatus) {
        switch s {
        case .listening:
            listening = true
            statusText = inMeeting ? "In meeting — listening" : "Listening"
        case .stopped:
            listening = false
        case .needsAuth(let m), .unavailable(let m):
            listening = false
            statusText = m
        }
    }

    // MARK: - Ingest a finalized transcript segment

    private func ingest(text: String, start: Date, end: Date) {
        var seg = TranscriptSegment(text: text, start: start, end: end)

        // 1. Keyword marking.
        let lower = text.lowercased()
        let hits = Config.markers.filter { lower.contains($0) }
        if !hits.isEmpty { seg.marked = true; seg.markers = hits }

        // 2. Meeting open / close by spoken phrase.
        if Config.meetingStartPhrases.contains(where: { lower.contains($0) }) {
            startMeeting(title: nil)
        } else if Config.meetingStopPhrases.contains(where: { lower.contains($0) }) {
            endMeeting()
        }

        // 3. Route to the current session and store.
        seg.sessionId = currentSession?.id
        segments.append(seg)
        Store.saveSegments(segments)
        statusText = seg.marked ? "Marked important" : (inMeeting ? "In meeting — listening" : "Listening")

        // 4. Optional spoken answer to "hey Nemo …".
        if Config.wakeAnswerEnabled, let q = wakeQuestion(in: lower, original: text) {
            answer(q)
        }

        // 5. Consolidate when enough has piled up.
        if unconsolidatedCount >= Config.consolidateMinSegments { consolidateNow() }
    }

    private func wakeQuestion(in lower: String, original: String) -> String? {
        var best: Range<String.Index>?
        for word in Config.wakeWords {
            for prefix in wakePrefixes {
                if let r = lower.range(of: prefix + word), best == nil || r.lowerBound < best!.lowerBound {
                    best = r
                }
            }
        }
        guard let r = best else { return nil }
        let q = String(original[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return q.count >= 3 ? q : nil
    }

    // MARK: - Sessions

    private func ensureAmbientSession() {
        let cal = Calendar.current
        let hasToday = sessions.contains {
            $0.kind == .ambient && $0.isOpen && cal.isDateInToday($0.start)
        }
        if !hasToday {
            let title = Self.dayTitle(Date())
            sessions.append(Session(title: title, kind: .ambient))
            Store.saveSessions(sessions)
        }
    }

    func startMeeting(title: String?) {
        guard !inMeeting else { return }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (name?.isEmpty == false) ? name! : "Meeting \(Self.timeTitle(Date()))"
        sessions.append(Session(title: resolved, kind: .meeting))
        Store.saveSessions(sessions)
        statusText = "Meeting started: \(resolved)"
    }

    func endMeeting() {
        guard let idx = sessions.firstIndex(where: { $0.kind == .meeting && $0.isOpen }) else { return }
        sessions[idx].end = Date()
        let closed = sessions[idx]
        Store.saveSessions(sessions)
        statusText = "Meeting ended: \(closed.title)"
        // Distill the meeting immediately so its summary + memories are ready.
        consolidateSession(closed)
    }

    // MARK: - Consolidation

    private func startConsolidateTimer() {
        consolidateTimer?.invalidate()
        let interval = max(60, Config.consolidateMinutes * 60)
        consolidateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.consolidateNow() }
        }
    }

    /// Consolidate all not-yet-processed segments into memory.
    func consolidateNow() {
        guard !isConsolidating else { return }
        let pending = segments.filter { !$0.consolidated }
        guard pending.count >= 1 else { return }
        runConsolidation(of: pending, sessionTitle: inMeeting ? currentSession?.title : nil)
    }

    /// Consolidate just one session's segments (used when a meeting ends).
    private func consolidateSession(_ session: Session) {
        guard !isConsolidating else { return }
        let segs = segments.filter { $0.sessionId == session.id && !$0.consolidated }
        guard !segs.isEmpty else { return }
        runConsolidation(of: segs, sessionTitle: session.title, summarize: session.id)
    }

    private func runConsolidation(of pending: [TranscriptSegment], sessionTitle: String?,
                                  summarize sessionId: UUID? = nil) {
        isConsolidating = true
        statusText = "Consolidating memory…"
        let snapshot = memories
        let model = Config.memoryModel
        let ids = Set(pending.map { $0.id })

        Task {
            do {
                let out = try await Consolidator.consolidate(segments: pending, existing: snapshot,
                                                            model: model, sessionTitle: sessionTitle)
                await MainActor.run {
                    self.memories = out.memories
                    Store.saveMemories(self.memories)
                    for i in self.segments.indices where ids.contains(self.segments[i].id) {
                        self.segments[i].consolidated = true
                    }
                    Store.saveSegments(self.segments)
                    if let sid = sessionId, let s = out.summary,
                       let idx = self.sessions.firstIndex(where: { $0.id == sid }) {
                        self.sessions[idx].summary = s
                        Store.saveSessions(self.sessions)
                    }
                    self.isConsolidating = false
                    self.statusText = "Memory updated (+\(out.created) new, \(out.updated) refined)"
                }
            } catch {
                await MainActor.run {
                    self.isConsolidating = false
                    self.statusText = "Consolidation failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Import outside context

    func refreshImportSources() {
        Task {
            let found = await Task.detached { ContextImporter.discover() }.value
            await MainActor.run { self.importSources = found }
        }
    }

    func importContext(_ source: ContextImporter.Source) {
        guard !isImporting else { return }
        isImporting = true
        statusText = "Importing \(source.label)…"
        let snapshot = memories
        let model = Config.memoryModel
        let label = source.label
        Task {
            do {
                let out: Consolidator.Output
                if source.assistant == "claude" {
                    // Claude memories are already structured — parse them directly (no LLM).
                    out = await Task.detached { ContextImporter.importClaudeStructured(into: snapshot) }.value
                } else {
                    out = try await ContextImporter.importSource(source, into: snapshot, model: model) { done, total in
                        Task { @MainActor in self.statusText = "Importing \(label)… \(done)/\(total)" }
                    }
                }
                await MainActor.run {
                    self.memories = out.memories
                    Store.saveMemories(self.memories)
                    self.isImporting = false
                    self.statusText = "Imported \(label): +\(out.created) new, \(out.updated) updated"
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.statusText = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Spoken answers ("hey Nemo …")

    private func answer(_ question: String) {
        guard !answering else { return }
        answering = true
        statusText = "Asking Claude…"
        let model = Config.memoryModel
        let sys = "You are a friendly voice assistant answering out loud. Reply in one to three short, conversational sentences of plain spoken English — no markdown, lists, or URLs."
        Task {
            do {
                let reply = try await AssistantRunner.claudeOneShot(prompt: question, system: sys, model: model)
                await MainActor.run {
                    self.lastAnswer = reply
                    self.statusText = "Answering aloud…"
                    self.speaker.onFinish = { [weak self] in
                        self?.answering = false
                        self?.statusText = self?.inMeeting == true ? "In meeting — listening" : "Listening"
                    }
                    self.speaker.speak(reply)
                }
            } catch {
                await MainActor.run {
                    self.answering = false
                    self.statusText = "Couldn't answer: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Editing

    func deleteMemory(_ id: UUID) {
        memories.removeAll { $0.id == id }
        for i in memories.indices { memories[i].links.removeAll { $0 == id } }
        Store.saveMemories(memories)
    }

    func toggleMark(_ segmentId: UUID) {
        guard let i = segments.firstIndex(where: { $0.id == segmentId }) else { return }
        segments[i].marked.toggle()
        if segments[i].marked, segments[i].markers.isEmpty { segments[i].markers = ["manual"] }
        Store.saveSegments(segments)
    }

    func clearTranscript() {
        segments.removeAll()
        Store.saveSegments(segments)
    }

    // MARK: - Formatting helpers

    static func dayTitle(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .none
        return f.string(from: d)
    }
    static func timeTitle(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: d)
    }
}

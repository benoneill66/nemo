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
    @Published private(set) var speakers: [SpeakerIdentity] = []

    // Live UI state
    @Published private(set) var listening = false
    @Published private(set) var statusText = "Idle"
    @Published private(set) var partialText = ""           // what's being heard right now
    @Published private(set) var isConsolidating = false
    @Published private(set) var isImporting = false
    @Published private(set) var isDeduping = false           // graph maintenance in flight (plan 03)
    @Published private(set) var lastAnswer: String?        // last spoken "hey Nemo" reply
    @Published private(set) var importSources: [ContextImporter.Source] = []
    @Published private(set) var surfaced: [SurfacedMemory] = []  // relevant-right-now memories
    @Published private(set) var briefing: Briefing?              // today's morning briefing
    @Published private(set) var isBriefing = false
    @Published var briefingDismissed = false                    // hidden for this session
    @Published private(set) var speakingBriefing = false
    @Published private(set) var assistantHealth: AssistantError? // nil = CLI healthy (plan 08)
    @Published private(set) var usage: [UsageEvent] = []         // metered LLM activity (plan 09)

    private let engine: SpeechEngine = makeSpeechEngine()
    private let speaker = Speaker()
    private let diarizer = SpeakerDiarizer(threshold: Float(Config.speakerThreshold))
    private let embeddings = EmbeddingIndex()   // on-device semantic index (plans 01, 11)

    /// Which transcription backend is active (shown in the UI).
    var engineName: String { engine.displayName }

    private var consolidateTimer: Timer?
    private var surfaceTimer: Timer?
    private var answering = false
    private var consolidateRetries = 0   // backoff counter for transient CLI failures (plan 08)
    private var createdSinceDedupe = 0    // new memories since the last dedupe pass (plan 03)

    private let wakePrefixes = ["hey ", "hey, ", "okay ", "ok ", "hi ", "yo "]

    init() {
        Store.migrateLegacyConfigIfNeeded()
        segments = Store.loadSegments()
        memories = Store.loadMemories()
        sessions = Store.loadSessions()
        speakers = Store.loadSpeakers()
        briefing = Store.loadBriefing()
        // Restore learned voices so returning speakers keep their identity (and name).
        diarizer.seed(speakers.map { (id: $0.id, centroid: $0.centroid, count: $0.count) })
        usage = Store.loadUsage()
        assistantHealth = AssistantRunner.health()   // probe CLI availability up front
        // Meter every Claude CLI call into the usage log (plans 08/09). Metadata only.
        AssistantRunner.onUsage = { [weak self] event in
            Task { @MainActor in self?.recordUsage(event) }
        }
        refreshImportSources()   // walks ~/.claude off the main thread
        maybeDecay()             // relax stale reinforcement weights, once per day
        maybeAutoBrief()         // generate today's briefing if we haven't already
        // Build the semantic index after init returns, so it doesn't block launch.
        Task { @MainActor in self.embeddings.sync(self.memories) }

        engine.onStatus = { [weak self] s in self?.handleStatus(s) }
        engine.onPartial = { [weak self] t in self?.partialText = t }
        engine.onSegment = { [weak self] text, start, end, voice in
            self?.ingest(text: text, start: start, end: end, voice: voice)
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
        memories.filter { $0.categoryEnum == category && !$0.superseded }
            .sorted { $0.effectiveImportance != $1.effectiveImportance
                ? $0.effectiveImportance > $1.effectiveImportance : $0.updated > $1.updated }
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
        startSurfaceTimer()
    }

    func stop() {
        engine.stop()
        consolidateTimer?.invalidate(); consolidateTimer = nil
        surfaceTimer?.invalidate(); surfaceTimer = nil
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

    private func ingest(text: String, start: Date, end: Date, voice: VoiceFingerprint? = nil) {
        var seg = TranscriptSegment(text: text, start: start, end: end)

        // 0. Attribute the segment to a speaker by clustering its voice fingerprint.
        if let voice { seg.speaker = attributeSpeaker(voice) }

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

        // 4. Surface memories relevant to what was just said.
        if Config.surfaceEnabled { refreshSurfaced() }

        // 5. Optional spoken answer to "hey Nemo …".
        if Config.wakeAnswerEnabled, let q = wakeQuestion(in: lower, original: text) {
            answer(q)
        }

        // 6. Consolidate when enough has piled up.
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

    // MARK: - Speakers

    /// Cluster a voice fingerprint into a speaker id, materializing (or refreshing) its persisted
    /// identity. New voices get a default "Speaker N" name the user can change later.
    private func attributeSpeaker(_ voice: VoiceFingerprint) -> Int {
        let id = diarizer.assign(voice)
        let profile = diarizer.profiles.first { $0.id == id }
        if let idx = speakers.firstIndex(where: { $0.id == id }) {
            // Keep the learned centroid in sync so a returning voice keeps matching.
            if let profile {
                speakers[idx].centroid = profile.centroid
                speakers[idx].count = profile.count
            }
        } else {
            speakers.append(SpeakerIdentity(id: id, name: "Speaker \(id + 1)",
                                            centroid: profile?.centroid ?? voice.features,
                                            count: profile?.count ?? 1))
        }
        Store.saveSpeakers(speakers)
        return id
    }

    func speaker(_ id: Int?) -> SpeakerIdentity? {
        guard let id else { return nil }
        return speakers.first { $0.id == id }
    }
    func speakerName(_ id: Int?) -> String? { speaker(id)?.name }

    /// Give a speaker a real name. Empty input reverts it to the default "Speaker N".
    func renameSpeaker(_ id: Int, to name: String) {
        guard let idx = speakers.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            speakers[idx].name = "Speaker \(id + 1)"
            speakers[idx].renamed = false
        } else {
            speakers[idx].name = trimmed
            speakers[idx].renamed = true
        }
        Store.saveSpeakers(speakers)
    }

    /// Speakers that have actually appeared in the retained transcript, most-recent first —
    /// what the UI offers for at-a-glance review and renaming.
    var activeSpeakers: [SpeakerIdentity] {
        let present = Set(segments.compactMap(\.speaker))
        return speakers.filter { present.contains($0.id) }.sorted { $0.id < $1.id }
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
        // Explicit meetings are consolidated wholesale — the user chose to record them, so we
        // don't second-guess relevance there. Ambient chatter goes through the cheap gate.
        let useGate = Config.relevanceGateEnabled && sessionId == nil
        let gateModel = Config.gateModel
        let ids = Set(pending.map { $0.id })
        let speakerNames = Dictionary(speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

        Task {
            do {
                // 1. Cheap relevance gate: keep only segments worth remembering; discard the
                //    rest. If the gate fails, fall back to keeping everything (old behaviour).
                var relevant = pending
                var junkIds: Set<UUID> = []
                if useGate {
                    let keep = (try? await Consolidator.gate(segments: pending, model: gateModel))
                        ?? Set(pending.indices)
                    relevant = pending.enumerated().filter { keep.contains($0.offset) }.map(\.element)
                    junkIds = Set(pending.enumerated().filter { !keep.contains($0.offset) }.map(\.element.id))
                }

                // 2. Nothing worth remembering — drop the junk, skip the expensive call entirely.
                if relevant.isEmpty {
                    await MainActor.run {
                        self.segments.removeAll { junkIds.contains($0.id) }
                        self.pruneConsolidatedTranscript()
                        Store.saveSegments(self.segments)
                        self.isConsolidating = false
                        self.clearAssistantHealth()
                        if useGate { self.noteGateOutcome(kept: 0, dropped: junkIds.count) }
                        self.statusText = "Nothing to remember (\(junkIds.count) dropped)"
                    }
                    return
                }

                // 3. Distill the relevant segments into memory with the full model.
                let out = try await Consolidator.consolidate(segments: relevant, existing: snapshot,
                                                            model: model, sessionTitle: sessionTitle,
                                                            speakerNames: speakerNames)
                await MainActor.run {
                    self.memories = out.memories
                    Store.saveMemories(self.memories)
                    self.embeddings.sync(self.memories)
                    self.segments.removeAll { junkIds.contains($0.id) }
                    for i in self.segments.indices where ids.contains(self.segments[i].id) {
                        self.segments[i].consolidated = true
                    }
                    self.pruneConsolidatedTranscript()
                    Store.saveSegments(self.segments)
                    if let sid = sessionId, let s = out.summary,
                       let idx = self.sessions.firstIndex(where: { $0.id == sid }) {
                        self.sessions[idx].summary = s
                        Store.saveSessions(self.sessions)
                    }
                    self.isConsolidating = false
                    self.clearAssistantHealth()
                    if useGate { self.noteGateOutcome(kept: relevant.count, dropped: junkIds.count) }
                    let dropped = junkIds.isEmpty ? "" : ", \(junkIds.count) dropped"
                    self.statusText = "Memory updated (+\(out.created) new, \(out.updated) refined\(dropped))"
                    // Periodically tidy the graph once enough new memories have accumulated.
                    self.createdSinceDedupe += out.created
                    if Config.dedupeEnabled, self.createdSinceDedupe >= Config.dedupeEveryNNew {
                        self.createdSinceDedupe = 0
                        self.maintainNow()
                    }
                }
            } catch {
                await MainActor.run {
                    self.isConsolidating = false
                    self.handleAssistantFailure(error, context: "Consolidation",
                                                retry: { [weak self] in self?.consolidateNow() })
                }
            }
        }
    }

    /// Bound transcript growth: once a segment has been folded into memory, the raw text is
    /// only useful for a while. Drop consolidated segments past the retention window — but
    /// always keep user-marked segments and meeting transcripts.
    private func pruneConsolidatedTranscript() {
        let days = Config.transcriptRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let meetingSessions = Set(sessions.filter { $0.kind == .meeting }.map(\.id))
        // Keep any segment a memory cites as its provenance (plan 05) so "view source" never
        // dead-ends. Bounded because provenance ids are capped per memory.
        let cited = Set(memories.flatMap(\.sourceSegmentIds))
        segments.removeAll { seg in
            seg.consolidated && !seg.marked && seg.end < cutoff
                && !cited.contains(seg.id)
                && !(seg.sessionId.map(meetingSessions.contains) ?? false)
        }
    }

    // MARK: - Surfacing relevant memories

    /// Periodically fades out surfaced cards once the conversation has moved past them, even
    /// when no new speech is arriving, so the strip reflects *now* rather than a while ago.
    private func startSurfaceTimer() {
        surfaceTimer?.invalidate()
        surfaceTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneSurfaced() }
        }
    }

    /// Re-rank memories against the last little while of speech and merge into the live set:
    /// refresh anything that re-matched, keep recent matches decaying, drop the stale.
    private func refreshSurfaced() {
        let live = liveMemories   // never surface archived (superseded) memories
        guard !live.isEmpty else { if !surfaced.isEmpty { surfaced = [] }; return }

        let now = Date()
        let window = Config.surfaceWindowSeconds
        let recentText = segments
            .filter { now.timeIntervalSince($0.end) <= window }
            .suffix(12)
            .map(\.text)
            .joined(separator: " ") + " " + partialText

        let hits: [Surfacer.Hit]
        if Config.semanticSurfaceEnabled, embeddings.isAvailable {
            let neighbours = embeddings.search(recentText, limit: 20)
            let semantic = Dictionary(neighbours.map { ($0.id, $0.score) }, uniquingKeysWith: { a, _ in a })
            hits = Surfacer.rankHybrid(recent: recentText, memories: live, semantic: semantic,
                                       semanticWeight: Config.semanticWeight, semanticFloor: Config.semanticFloor,
                                       minScore: Config.surfaceMinScore, limit: Config.surfaceMax)
        } else {
            hits = Surfacer.rank(recent: recentText, memories: live,
                                 minScore: Config.surfaceMinScore, limit: Config.surfaceMax)
        }
        let hitIds = Set(hits.map { $0.memory.id })

        // Reinforcement (plan 02): a memory that *freshly* surfaces (wasn't already showing) gets
        // a small, capped weight bump. Same-topic talk keeps cards in `surfaced`, so this only
        // fires on genuine topic shifts — writes are bounded by those, not by the tick rate.
        if Config.reinforcementEnabled {
            let prevIds = Set(surfaced.map(\.id))
            var bumped = false
            for h in hits where !prevIds.contains(h.memory.id) {
                if let i = memories.firstIndex(where: { $0.id == h.memory.id }) {
                    memories[i].hitCount += 1
                    memories[i].lastSurfaced = now
                    memories[i].weight = Reinforcement.reinforced(memories[i].weight)
                    bumped = true
                }
            }
            if bumped { Store.saveMemories(memories) }
        }

        var merged: [SurfacedMemory] = []
        // Carry forward still-fresh cards that didn't re-match this round (let them decay).
        for s in surfaced where !hitIds.contains(s.id)
            && now.timeIntervalSince(s.lastHit) <= Config.surfaceTTLSeconds {
            merged.append(s)
        }
        // Add / refresh this round's hits, preserving each card's original firstSeen.
        for h in hits {
            let firstSeen = surfaced.first { $0.id == h.memory.id }?.firstSeen ?? now
            merged.append(SurfacedMemory(memory: h.memory, score: h.score, reason: h.reason,
                                         firstSeen: firstSeen, lastHit: now))
        }

        surfaced = Array(merged.sorted { $0.lastHit != $1.lastHit ? $0.lastHit > $1.lastHit
                                                                   : $0.score > $1.score }
                               .prefix(Config.surfaceMax))
    }

    /// Drop cards whose last match is older than the time-to-live.
    private func pruneSurfaced() {
        guard !surfaced.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-Config.surfaceTTLSeconds)
        let kept = surfaced.filter { $0.lastHit > cutoff }
        if kept.count != surfaced.count { surfaced = kept }
    }

    func dismissSurfaced(_ id: UUID) { surfaced.removeAll { $0.id == id } }

    // MARK: - Morning briefing

    /// On launch, generate today's briefing once — if it's enabled, there's something to
    /// brief on, and we haven't already done one today (cached briefings survive relaunches).
    private func maybeAutoBrief() {
        guard Config.briefingEnabled, !memories.isEmpty else { return }
        if briefing?.isFromToday == true { return }
        generateBriefing(speak: Config.briefingSpeak)
    }

    /// Build a fresh briefing from the current memory graph + recent sessions.
    func generateBriefing(speak: Bool = false) {
        guard !isBriefing, !memories.isEmpty else { return }
        isBriefing = true
        briefingDismissed = false
        let snapshot = liveMemories, sess = sessions, model = Config.memoryModel
        Task {
            do {
                let text = try await Briefer.generate(memories: snapshot, sessions: sess, model: model)
                await MainActor.run {
                    let b = Briefing(text: text, generated: Date())
                    self.briefing = b
                    Store.saveBriefing(b)
                    self.isBriefing = false
                    if speak { self.speakBriefing() }
                }
            } catch {
                await MainActor.run {
                    self.isBriefing = false
                    self.statusText = "Briefing failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func speakBriefing() {
        guard let text = briefing?.text else { return }
        speakingBriefing = true
        speaker.onFinish = { [weak self] in self?.speakingBriefing = false }
        speaker.speak(text)
    }
    func stopSpeaking() { speaker.stop(); speakingBriefing = false }
    func dismissBriefing() { briefingDismissed = true }

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
                    self.embeddings.sync(self.memories)
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

    /// Retrieve the user's own memories most relevant to a spoken question — union of semantic
    /// neighbours and lexical hits, deduped, archived excluded, capped at `answerMemoryK` (plan 11).
    private func retrieveForQuestion(_ question: String) -> [Memory] {
        let k = max(1, Config.answerMemoryK)
        var ranked: [UUID] = []
        if Config.semanticSurfaceEnabled, embeddings.isAvailable {
            ranked = embeddings.search(question, limit: k * 2).map(\.id)
        }
        let lexical = Surfacer.rank(recent: question, memories: liveMemories, minScore: 1, limit: k).map(\.memory.id)

        var seen = Set<UUID>(); var result: [Memory] = []
        for id in ranked + lexical {
            guard !seen.contains(id), let m = memory(id), !m.superseded else { continue }
            seen.insert(id); result.append(m)
            if result.count >= k { break }
        }
        return result
    }

    /// The last little while of speech, for conversational follow-ups in grounded answers.
    private func recentTranscriptWindow() -> String {
        let now = Date()
        return segments
            .filter { now.timeIntervalSince($0.end) <= Config.surfaceWindowSeconds }
            .suffix(8).map(\.text).joined(separator: " ")
    }

    /// Reinforce memories that grounded an answer — being asked about is strong relevance (plan 11/02).
    private func reinforceUsed(_ ids: [UUID]) {
        guard Config.reinforcementEnabled, !ids.isEmpty else { return }
        let now = Date(); var changed = false
        for id in ids where memories.contains(where: { $0.id == id }) {
            if let i = memories.firstIndex(where: { $0.id == id }) {
                memories[i].hitCount += 1
                memories[i].lastSurfaced = now
                memories[i].weight = Reinforcement.reinforced(memories[i].weight)
                changed = true
            }
        }
        if changed { Store.saveMemories(memories) }
    }

    private func answer(_ question: String) {
        guard !answering else { return }
        answering = true
        statusText = "Asking Claude…"
        let model = Config.memoryModel

        // Retrieval-augmented (plan 11): answer from the user's own memories first.
        let grounded = Config.memoryGroundedAnswers
        let retrieved = grounded ? retrieveForQuestion(question) : []
        let sys = grounded ? MemoryQA.system :
            "You are a friendly voice assistant answering out loud. Reply in one to three short, conversational sentences of plain spoken English — no markdown, lists, or URLs."
        let prompt = grounded ? MemoryQA.prompt(question: question, memories: retrieved,
                                                recent: recentTranscriptWindow()) : question
        let usedIds = retrieved.map(\.id)
        Task {
            do {
                let reply = try await AssistantRunner.claudeOneShot(prompt: prompt, system: sys,
                                                                   model: model, feature: "answer")
                await MainActor.run {
                    self.reinforceUsed(usedIds)   // being asked about is a strong relevance signal
                    self.lastAnswer = reply
                    self.clearAssistantHealth()
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
                    if let ae = error as? AssistantError, ae.isHardDown { self.assistantHealth = ae }
                    self.statusText = "Couldn't answer: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - CLI resilience & usage (plans 08 / 09)

    /// A successful CLI call proves the assistant is healthy — clear any banner and reset backoff.
    private func clearAssistantHealth() {
        if assistantHealth != nil { assistantHealth = nil }
        consolidateRetries = 0
    }

    /// Classify a failed CLI call: surface hard-down states (install/login) as a persistent
    /// banner, and schedule a backoff retry for transient ones (rate limit / timeout / generic).
    private func handleAssistantFailure(_ error: Error, context: String, retry: @escaping () -> Void) {
        guard let ae = error as? AssistantError else {
            statusText = "\(context) failed: \(error.localizedDescription)"
            return
        }
        statusText = "\(context): \(ae.localizedDescription)"
        if ae.isHardDown { assistantHealth = ae }
        guard ae.isTransient, consolidateRetries < Config.maxRetries else { return }

        // Exponential backoff, honouring a server-provided retry-after when present.
        var delay = Config.retryBackoffSeconds * pow(2, Double(consolidateRetries))
        if case .rateLimited(let after?) = ae { delay = max(delay, after) }
        consolidateRetries += 1
        let attempt = consolidateRetries
        statusText = "\(context) will retry (attempt \(attempt)) in \(Int(delay))s…"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            retry()
        }
    }

    /// Append a metered LLM event, trim to the retention window, and persist (metadata only).
    private func recordUsage(_ event: UsageEvent) {
        guard Config.usageTrackingEnabled else { return }
        usage.append(event)
        let cutoff = Date().addingTimeInterval(-Double(Config.usageRetentionDays) * 86_400)
        usage.removeAll { $0.at < cutoff }
        Store.saveUsage(usage)
    }

    /// Record how many segments the relevance gate kept vs dropped, so the Activity view can show
    /// what it's saving. Rides on a synthetic (duration-0) usage row, not counted as a CLI call.
    private func noteGateOutcome(kept: Int, dropped: Int) {
        guard Config.usageTrackingEnabled, kept + dropped > 0 else { return }
        recordUsage(UsageEvent(feature: "gate", model: Config.gateModel ?? "default", durationMs: 0,
                               outcome: "ok", keptSegments: kept, droppedSegments: dropped))
    }

    /// Usage rolled up over the last `days` (default: today + 6 = 7-day window).
    func usageRollup(days: Int = 7) -> UsageRollup {
        let since = Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(days - 1) * 86_400))
        return usage.rollup(since: since)
    }

    // MARK: - Graph maintenance: dedupe + supersede (plans 03 & 04)

    /// Memories that are live (not archived by a supersession).
    var liveMemories: [Memory] { memories.filter { !$0.superseded } }
    var archivedMemories: [Memory] { memories.filter { $0.superseded } }

    /// Generate duplicate + contradiction candidates on-device, adjudicate with the cheap model,
    /// and apply merges/supersessions. No-op while other LLM work is in flight.
    func maintainNow() {
        guard Config.dedupeEnabled, !isConsolidating, !isDeduping, memories.count > 1 else { return }
        let snapshot = memories
        let cosine: (Int, Int) -> Double? = { i, j in self.embeddings.cosine(snapshot[i].id, snapshot[j].id) }
        let pairs = Config.contradictionDetectionEnabled
            ? Consolidator.maintenancePairs(snapshot, cosine: cosine, cosineThreshold: Config.dedupeCosine)
            : Consolidator.candidatePairs(snapshot, cosine: cosine, cosineThreshold: Config.dedupeCosine)
        guard !pairs.isEmpty else { return }

        isDeduping = true
        statusText = "Tidying memory…"
        let model = Config.gateModel
        Task {
            do {
                let out = try await Consolidator.maintain(memories: snapshot, pairs: pairs, model: model)
                await MainActor.run {
                    self.memories = out.memories
                    Store.saveMemories(self.memories)
                    self.embeddings.sync(self.memories)
                    self.isDeduping = false
                    self.clearAssistantHealth()
                    if out.updated > 0 { self.statusText = "Tidied memory (\(out.updated) merged/updated)" }
                }
            } catch {
                await MainActor.run {
                    self.isDeduping = false
                    self.handleAssistantFailure(error, context: "Tidy", retry: {})
                }
            }
        }
    }

    /// Bring an archived memory back (undo a supersession).
    func restoreMemory(_ id: UUID) {
        guard let i = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[i].superseded = false
        memories[i].supersededBy = nil
        Store.saveMemories(memories)
        embeddings.sync(memories)
    }

    // MARK: - Reinforcement decay (plan 02)

    private static let lastDecayKey = "nemo.lastDecay"

    /// Once per day, decay learned weights toward base importance. Pinned memories are exempt.
    private func maybeDecay() {
        guard Config.reinforcementEnabled else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastDecayKey) as? Date
        if let last, Calendar.current.isDateInToday(last) { return }
        decayWeights()
        UserDefaults.standard.set(Date(), forKey: Self.lastDecayKey)
    }

    private func decayWeights() {
        let now = Date()
        let halfLife = Config.decayHalfLifeDays
        var changed = false
        for i in memories.indices where !memories[i].pinned && memories[i].weight > 0 {
            let ref = memories[i].lastSurfaced ?? memories[i].updated
            let decayed = Reinforcement.decayed(memories[i].weight, lastRef: ref, now: now, halfLifeDays: halfLife)
            if decayed != memories[i].weight { memories[i].weight = decayed; changed = true }
        }
        if changed { Store.saveMemories(memories) }
    }

    // MARK: - Editing

    func deleteMemory(_ id: UUID) {
        memories.removeAll { $0.id == id }
        for i in memories.indices { memories[i].links.removeAll { $0 == id } }
        embeddings.remove(id)
        Store.saveMemories(memories)
    }

    // MARK: - Memory editing & provenance (plan 05)

    /// Apply a user edit. Marks the memory `userEdited` so consolidation won't clobber the text,
    /// re-embeds it, and persists. Pass nil for any field to leave it unchanged.
    func updateMemory(_ id: UUID, title: String? = nil, content: String? = nil, category: String? = nil) {
        guard let i = memories.firstIndex(where: { $0.id == id }) else { return }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            memories[i].title = title
        }
        if let content = content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
            memories[i].content = content
        }
        if let category, !category.isEmpty { memories[i].category = Category.match(category).rawValue }
        memories[i].userEdited = true
        memories[i].updated = Date()
        embeddings.sync(memories)
        Store.saveMemories(memories)
    }

    func setImportance(_ id: UUID, _ value: Int) {
        guard let i = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[i].importance = min(5, max(1, value))
        memories[i].updated = Date()
        Store.saveMemories(memories)
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let i = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[i].pinned = pinned
        Store.saveMemories(memories)
    }

    /// The transcript segments a memory was distilled from (provenance), oldest first.
    func sourceSegments(for id: UUID) -> [TranscriptSegment] {
        guard let mem = memory(id) else { return [] }
        let ids = Set(mem.sourceSegmentIds)
        return segments.filter { ids.contains($0.id) }.sorted { $0.start < $1.start }
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

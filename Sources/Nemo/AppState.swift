import Foundation
import SwiftUI
import AppKit

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
    @Published private(set) var people: [Person] = []          // first-class people directory (plan 16)

    // Live UI state
    @Published private(set) var listening = false
    @Published private(set) var statusText = "Idle"
    @Published private(set) var partialText = ""           // what's being heard right now
    /// Live mic loudness for the waveform. Deliberately *not* `@Published` on `AppState`: the audio
    /// tap fires ~47×/s, and republishing the whole app state that often re-rendered every view. It
    /// lives in its own observable so only the waveform reacts. See `AudioMeter`.
    let meter = AudioMeter()
    @Published private(set) var isConsolidating = false
    @Published private(set) var isImporting = false
    @Published private(set) var isDeduping = false           // graph maintenance in flight (plan 03)
    @Published private(set) var isDreaming = false           // dream consolidation in flight (plan 17)
    @Published private(set) var lastAnswer: String?        // last spoken "hey Nemo" reply
    @Published private(set) var importSources: [ContextImporter.Source] = []
    @Published private(set) var gmailConnected = GmailService.isConnected   // Gmail linked (plan 15)
    @Published private(set) var gmailAccount: String? = GmailService.connectedAccount
    @Published private(set) var gmailBusy = false                           // connecting or pulling
    @Published private(set) var calendarBusy = false                        // calendar sync in flight
    @Published private(set) var calendarHasAccess = CalendarService.hasAccess  // EventKit event access
    @Published private(set) var surfaced: [SurfacedMemory] = []  // relevant-right-now memories
    @Published private(set) var briefing: Briefing?              // today's morning briefing
    @Published private(set) var isBriefing = false
    @Published var briefingDismissed = false                    // hidden for this session
    @Published private(set) var speakingBriefing = false
    @Published private(set) var assistantHealth: AssistantError? // nil = CLI healthy (plan 08)
    @Published private(set) var usage: [UsageEvent] = []         // metered LLM activity (plan 09)
    @Published private(set) var pausedUntil: Date?              // timed private-mode pause (plan 06)

    private let engine: SpeechEngine = makeSpeechEngine()
    private let speaker = Speaker()
    private let diarizer = SpeakerDiarizer(threshold: Float(Config.speakerThreshold))
    private let embeddings = EmbeddingIndex()   // on-device semantic index (plans 01, 11)
    private let eventKit = EventKitExporter()    // Reminders export (plan 13)
    private let calendar = CalendarService()      // Calendar sync into memory

    /// Which transcription backend is active (shown in the UI).
    var engineName: String { engine.displayName }

    private var consolidateTimer: Timer?
    private var surfaceTimer: Timer?
    private var answering = false
    private var consolidateRetries = 0   // backoff counter for transient CLI failures (plan 08)
    private var createdSinceDedupe = 0    // new memories since the last dedupe pass (plan 03)
    private var pauseTimer: Timer?        // auto-resume after a timed pause (plan 06)
    private var autoPausedForApp = false  // paused because a sensitive app came to front (plan 06)
    private var overlay: OverlayController?  // floating "listening" bar (plan 14)

    /// Reopen/raise the main window. Captured from the main scene at launch (the
    /// `OpenWindowAction` value stays valid for the app's lifetime, so it still works
    /// after the window has been closed). Lets the floating overlay surface the app.
    var openMainWindow: (() -> Void)?

    private let wakePrefixes = ["hey ", "hey, ", "okay ", "ok ", "hi ", "yo "]

    init() {
        Store.migrateLegacyConfigIfNeeded()
        segments = Store.loadSegments()
        memories = Store.loadMemories()
        sessions = Store.loadSessions()
        speakers = Store.loadSpeakers()
        people = Store.loadPeople()
        briefing = Store.loadBriefing()
        // Restore learned voices so returning speakers keep their identity (and name).
        diarizer.seed(speakers.map { (id: $0.id, centroid: $0.centroid, count: $0.count) })
        usage = Store.loadUsage()
        assistantHealth = AssistantRunner.health()   // probe CLI availability up front
        // Meter every Claude CLI call into the usage log (plans 08/09). Metadata only.
        AssistantRunner.onUsage = { [weak self] event in
            Task { @MainActor in self?.recordUsage(event) }
        }
        setupAppExclusionObserver()   // auto-pause near sensitive apps (plan 06)
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
        // Smoothing + throttling now live in the meter, off the main view-update path.
        engine.onLevel = { [weak self] lvl in self?.meter.update(lvl) }

        overlay = OverlayController(state: self)   // persistent floating bar (plan 14)
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

    // MARK: - Window

    /// Bring the main Nemo window to the front (reopening it if it was closed),
    /// and activate the app. Used by the floating overlay's "open app" button.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openMainWindow?()
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
        meter.reset()
        statusText = "Paused"
    }

    // MARK: - Privacy: pause & app exclusion (plan 06)

    /// Temporarily stop listening (private mode), auto-resuming after `seconds`.
    func pause(for seconds: TimeInterval) {
        guard listening else { return }
        stop()
        pausedUntil = Date().addingTimeInterval(seconds)
        statusText = "Paused (private mode)"
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.resumeFromPause() }
        }
    }

    /// Resume from a timed or app-triggered pause.
    func resumeFromPause() {
        pauseTimer?.invalidate(); pauseTimer = nil
        pausedUntil = nil
        autoPausedForApp = false
        start()
    }

    var isPaused: Bool { pausedUntil != nil || autoPausedForApp }

    private func setupAppExclusionObserver() {
        guard !Config.excludedApps.isEmpty else { return }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in self?.handleFrontmostApp(bundle) }
        }
    }

    private func handleFrontmostApp(_ bundle: String?) {
        let excluded = bundle.map { Config.excludedApps.contains($0) } ?? false
        if excluded, listening {
            stop()
            autoPausedForApp = true
            statusText = "Paused — sensitive app in focus"
        } else if !excluded, autoPausedForApp {
            resumeFromPause()
        }
    }

    private func handleStatus(_ s: SpeechEngineStatus) {
        switch s {
        case .listening:
            listening = true
            statusText = inMeeting ? "In meeting — listening" : "Listening"
        case .stopped:
            listening = false
            meter.reset()
        case .needsAuth(let m), .unavailable(let m):
            listening = false
            meter.reset()
            statusText = m
        }
    }

    // MARK: - Ingest a finalized transcript segment

    private func ingest(text: String, start: Date, end: Date, voice: VoiceFingerprint? = nil) {
        var seg = TranscriptSegment(text: text, start: start, end: end)

        // 0a. Spoken pause control (plan 06): drop the triggering segment entirely so any sensitive
        //     lead-in isn't captured, and stop listening for a while.
        let rawLower = text.lowercased()
        if Config.pausePhrases.contains(where: { rawLower.contains($0) }) {
            pause(for: 30 * 60)
            return
        }

        // 0b. Redact obviously-sensitive content before anything is stored or sent to the LLM.
        if Config.redactionEnabled {
            let (clean, did) = Redactor.scrub(text)
            if did { seg.text = clean; seg.redacted = true }
        }

        // 1. Attribute the segment to a speaker by clustering its voice fingerprint.
        if let voice { seg.speaker = attributeSpeaker(voice) }

        // 2. Keyword marking (on the post-redaction text).
        let lower = seg.text.lowercased()
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
        if Config.wakeAnswerEnabled, let q = wakeQuestion(in: lower, original: seg.text) {
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

    /// Give a speaker a real name. Empty input reverts it to the default "Speaker N". Naming a
    /// speaker also attaches its voice to a real Person (resolving an existing one by name, or
    /// creating one) — this is how voices become people (plan 16).
    func renameSpeaker(_ id: Int, to name: String) {
        guard let idx = speakers.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            speakers[idx].name = "Speaker \(id + 1)"
            speakers[idx].renamed = false
            detachSpeakerFromPerson(id)        // clearing the name unlinks the person too
        } else {
            speakers[idx].name = trimmed
            speakers[idx].renamed = true
            linkSpeaker(id, toPersonNamed: trimmed)
        }
        Store.saveSpeakers(speakers)
    }

    /// Speakers that have actually appeared in the retained transcript, most-recent first —
    /// what the UI offers for at-a-glance review and renaming.
    var activeSpeakers: [SpeakerIdentity] {
        let present = Set(segments.compactMap(\.speaker))
        return speakers.filter { present.contains($0.id) }.sorted { $0.id < $1.id }
    }

    // MARK: - People (plan 16)

    func person(_ id: UUID?) -> Person? {
        guard let id else { return nil }
        return people.first { $0.id == id }
    }

    /// The Person a speaker is attached to, if any.
    func person(forSpeaker speakerId: Int?) -> Person? {
        guard let sid = speakerId, let pid = speaker(sid)?.personId else { return nil }
        return person(pid)
    }

    /// People sorted for display: pinned first, then by how recently they were seen.
    var sortedPeople: [Person] {
        people.sorted {
            if $0.isMe != $1.isMe { return $0.isMe }       // the user themselves sorts first
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.lastSeen > $1.lastSeen
        }
    }

    /// The person the user marked as themselves, if any.
    var me: Person? { people.first { $0.isMe } }

    /// Find an existing person by an exact known-name match (case-insensitive).
    private func personIndex(named name: String) -> Int? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return people.firstIndex { $0.knownNames.contains(key) }
    }

    /// Attach a speaker's voice to a person identified by name — resolving an existing person
    /// (exact name match) or creating a new one. Conservative on purpose: it won't guess between
    /// two same-named people; the user can re-point the speaker via `attachSpeaker(_:toPersonId:)`.
    private func linkSpeaker(_ speakerId: Int, toPersonNamed name: String) {
        guard let sidx = speakers.firstIndex(where: { $0.id == speakerId }) else { return }
        let pid: UUID
        if let pIdx = personIndex(named: name) {
            pid = people[pIdx].id
            if !people[pIdx].speakerIds.contains(speakerId) { people[pIdx].speakerIds.append(speakerId) }
            people[pIdx].lastSeen = Date()
        } else {
            var p = Person(name: name.trimmingCharacters(in: .whitespaces), speakerIds: [speakerId])
            p.attributes["source"] = "voice"
            pid = p.id
            people.append(p)
        }
        speakers[sidx].personId = pid
        Store.savePeople(people)
        Store.saveSpeakers(speakers)
    }

    /// Re-point a speaker at a specific existing person (used from the UI person picker).
    func attachSpeaker(_ speakerId: Int, toPersonId personId: UUID) {
        guard let sidx = speakers.firstIndex(where: { $0.id == speakerId }),
              let pidx = people.firstIndex(where: { $0.id == personId }) else { return }
        // Remove this speaker from any other person first.
        for i in people.indices where i != pidx { people[i].speakerIds.removeAll { $0 == speakerId } }
        if !people[pidx].speakerIds.contains(speakerId) { people[pidx].speakerIds.append(speakerId) }
        speakers[sidx].personId = personId
        // Keep the speaker label in step with the person's name.
        speakers[sidx].name = people[pidx].name
        speakers[sidx].renamed = true
        Store.savePeople(people)
        Store.saveSpeakers(speakers)
    }

    private func detachSpeakerFromPerson(_ speakerId: Int) {
        guard let sidx = speakers.firstIndex(where: { $0.id == speakerId }) else { return }
        if let pid = speakers[sidx].personId,
           let pidx = people.firstIndex(where: { $0.id == pid }) {
            people[pidx].speakerIds.removeAll { $0 == speakerId }
            Store.savePeople(people)
        }
        speakers[sidx].personId = nil
    }

    // MARK: People editing & merge

    /// Replace a person's user-facing fields and mark them user-edited so automation won't clobber.
    func updatePerson(_ id: UUID, name: String? = nil, summary: String? = nil,
                      relationship: String? = nil) {
        guard let idx = people.firstIndex(where: { $0.id == id }) else { return }
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            // Keep the old name as an alias so prior references still resolve.
            if people[idx].name.lowercased() != name.lowercased(),
               !people[idx].aliases.contains(people[idx].name) {
                people[idx].aliases.append(people[idx].name)
            }
            people[idx].name = name
        }
        if let summary { people[idx].summary = summary }
        if let relationship { people[idx].attributes["relationship"] = relationship }
        people[idx].userEdited = true
        Store.savePeople(people)
        // Keep attached speaker labels in sync with the (possibly) new name.
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            for sid in people[idx].speakerIds {
                if let s = speakers.firstIndex(where: { $0.id == sid }) {
                    speakers[s].name = name; speakers[s].renamed = true
                }
            }
            Store.saveSpeakers(speakers)
        }
    }

    func setPersonPinned(_ id: UUID, _ pinned: Bool) {
        guard let idx = people.firstIndex(where: { $0.id == id }) else { return }
        people[idx].pinned = pinned
        Store.savePeople(people)
    }

    /// Mark (or unmark) a person as the user themselves. Exactly one person can be "me", so
    /// setting a new one clears any previous. Being "me" implies user-edited so automation won't
    /// fold this identity into a same-named person it sees later.
    func setPersonIsMe(_ id: UUID, _ isMe: Bool) {
        guard let idx = people.firstIndex(where: { $0.id == id }) else { return }
        if isMe {
            for i in people.indices where people[i].isMe { people[i].isMe = false }
            people[idx].isMe = true
            people[idx].userEdited = true
        } else {
            people[idx].isMe = false
        }
        Store.savePeople(people)
    }

    func deletePerson(_ id: UUID) {
        // Unlink any speakers pointing at this person.
        for i in speakers.indices where speakers[i].personId == id { speakers[i].personId = nil }
        people.removeAll { $0.id == id }
        Store.savePeople(people)
        Store.saveSpeakers(speakers)
    }

    /// Merge `sourceId` into `destId`: the destination absorbs the source's aliases, facts,
    /// attributes, linked memories and speakers, then the source is removed. This is the manual
    /// correction for "Nemo split one person into two" — never assume; let the user decide.
    func mergePeople(_ sourceId: UUID, into destId: UUID) {
        guard sourceId != destId,
              let s = people.first(where: { $0.id == sourceId }),
              let didx = people.firstIndex(where: { $0.id == destId }) else { return }
        var dest = people[didx]

        // Names: keep dest's canonical name; fold the source's names in as aliases.
        var aliasSet = Set(dest.aliases.map { $0.lowercased() })
        for n in ([s.name] + s.aliases) where !n.isEmpty {
            if n.lowercased() != dest.name.lowercased(), !aliasSet.contains(n.lowercased()) {
                dest.aliases.append(n); aliasSet.insert(n.lowercased())
            }
        }
        // Facts: append, dedup by normalized text.
        var seen = Set(dest.facts.map(\.dedupKey))
        for f in s.facts where !seen.contains(f.dedupKey) { dest.facts.append(f); seen.insert(f.dedupKey) }
        // Attributes: dest wins; fill blanks from source.
        for (k, v) in s.attributes where (dest.attributes[k]?.isEmpty ?? true) { dest.attributes[k] = v }
        dest.memoryIds = Array(Set(dest.memoryIds + s.memoryIds))
        dest.speakerIds = Array(Set(dest.speakerIds + s.speakerIds))
        dest.mentionCount += s.mentionCount
        dest.firstSeen = min(dest.firstSeen, s.firstSeen)
        dest.lastSeen = max(dest.lastSeen, s.lastSeen)
        dest.pinned = dest.pinned || s.pinned
        dest.isMe = dest.isMe || s.isMe
        dest.userEdited = dest.userEdited || s.userEdited
        dest.mergedFrom.append(s.id)
        dest.mergedFrom.append(contentsOf: s.mergedFrom)

        people[didx] = dest
        people.removeAll { $0.id == sourceId }
        // Re-point any speakers that were attached to the source.
        for i in speakers.indices where speakers[i].personId == sourceId { speakers[i].personId = destId }
        Store.savePeople(people)
        Store.saveSpeakers(speakers)
        statusText = "Merged \(s.name) into \(dest.name)"
    }

    // MARK: People building (runs after consolidation)

    /// After a consolidation round, enrich the people directory from the memories that were just
    /// created or updated: extract people, accumulate durable facts/attributes, and resolve each
    /// (match-or-new) against the existing directory — the human-like disambiguation that keeps
    /// two same-named people distinct. Bounded to one LLM call per round; falls back to a
    /// conservative deterministic attach if the model is unavailable.
    private func buildPeople(touched: [Memory]) {
        guard Config.peopleEnabled, !touched.isEmpty,
              PeopleBuilder.hasCandidates(in: touched) else { return }
        let snapshot = people
        let model = Config.memoryModel
        let titleToId = Dictionary(touched.map { ($0.title.lowercased(), $0.id) },
                                   uniquingKeysWith: { a, _ in a })
        Task {
            do {
                let resolutions = try await PeopleBuilder.resolve(touched: touched, existing: snapshot,
                                                                  model: model)
                await MainActor.run { self.applyPeopleResolutions(resolutions, titleToId: titleToId,
                                                                  touched: touched) }
            } catch {
                // Model unavailable or output unusable — keep things moving with a safe attach.
                await MainActor.run {
                    self.people = PeopleBuilder.resolveDeterministically(touched: touched,
                                                                         existing: self.people)
                    Store.savePeople(self.people)
                }
            }
        }
    }

    private func applyPeopleResolutions(_ resolutions: [PeopleBuilder.Resolution],
                                        titleToId: [String: UUID], touched: [Memory]) {
        let now = Date()
        let touchedById = Dictionary(touched.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in resolutions {
            let name = Self.cleanField(r.name) ?? ""
            guard !name.isEmpty else { continue }

            // Resolve the target person: the model's explicit match, else a safety-net exact-name
            // match (so we never duplicate a name we already store), else a brand-new person.
            var idx: Int?
            if let mid = r.match, mid.lowercased() != "null", let uid = UUID(uuidString: mid) {
                idx = people.firstIndex { $0.id == uid }
            }
            if idx == nil { idx = personIndex(named: name) }

            let memIds = (r.memories ?? []).compactMap { titleToId[$0.lowercased()] }
            let source = memIds.first.flatMap { touchedById[$0]?.source } ?? "transcript"

            if let i = idx {
                foldResolution(into: &people[i], r, name: name, memIds: memIds, source: source, now: now)
            } else {
                var p = Person(name: name, firstSeen: now, lastSeen: now)
                foldResolution(into: &p, r, name: name, memIds: memIds, source: source, now: now)
                people.append(p)
            }
        }
        Store.savePeople(people)
    }

    /// Fold one resolution's data into a person, deduping facts/aliases and respecting user edits.
    private func foldResolution(into p: inout Person, _ r: PeopleBuilder.Resolution,
                                name: String, memIds: [UUID], source: String, now: Date) {
        var aliasSet = Set(p.knownNames)
        func addAlias(_ raw: String) {
            guard let t = Self.cleanField(raw), !aliasSet.contains(t.lowercased()) else { return }
            p.aliases.append(t); aliasSet.insert(t.lowercased())
        }
        // Prefer a fuller name the model surfaced (e.g. "Priya" → "Priya Shah"), keeping the old
        // as an alias — but never override a name the user set by hand.
        if !p.userEdited, name.count > p.name.count,
           name.lowercased().contains(p.name.lowercased()) {
            addAlias(p.name); p.name = name
        } else if name.lowercased() != p.name.lowercased() {
            addAlias(name)
        }
        for a in (r.aliases ?? []) { addAlias(a) }

        if let role = Self.cleanField(r.role) { p.attributes["role"] = role }
        if let org = Self.cleanField(r.org) { p.attributes["org"] = org }
        if let email = Self.cleanField(r.email) { p.attributes["email"] = email }
        if let rel = Self.cleanField(r.relationship), (p.attributes["relationship"]?.isEmpty ?? true) {
            p.attributes["relationship"] = rel
        }

        var seen = Set(p.facts.map(\.dedupKey))
        for f in (r.facts ?? []) {
            guard let text = Self.cleanField(f), text.count > 1 else { continue }
            let fact = PersonFact(text: text, source: source, sourceMemoryId: memIds.first)
            if !seen.contains(fact.dedupKey) { p.facts.append(fact); seen.insert(fact.dedupKey) }
        }
        if p.facts.count > 40 { p.facts.removeFirst(p.facts.count - 40) }   // bound growth

        for id in memIds where !p.memoryIds.contains(id) { p.memoryIds.append(id) }
        p.mentionCount += 1
        p.lastSeen = now
    }

    /// Trim a model-supplied string and treat empty / "null" / "none" placeholders as absent.
    private static func cleanField(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        let l = t.lowercased()
        return (l == "null" || l == "none" || l == "n/a") ? nil : t
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

    /// One-tap meeting: open a meeting session and immediately begin listening so
    /// it actually captures audio. Safe to call when already listening.
    func quickStartMeeting(title: String? = nil) {
        startMeeting(title: title)
        if !listening { start() }
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

    /// Delete a session and its captured transcript segments. Memories already distilled
    /// from the session are left intact — they live independently of the session record.
    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        Store.saveSessions(sessions)
        segments.removeAll { $0.sessionId == id }
        Store.saveSegments(segments)
        statusText = "Session deleted"
    }

    // MARK: - Consolidation

    private func startConsolidateTimer() {
        consolidateTimer?.invalidate()
        let interval = max(60, Config.consolidateMinutes * 60)
        consolidateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.consolidateNow()
                self?.maybeDream()   // dream when quiet, gated to once per dreamMinHours (plan 17)
            }
        }
    }

    /// Consolidate all not-yet-processed segments into memory.
    func consolidateNow() {
        guard !isConsolidating, !isDeduping, !isImporting else { return }
        let pending = segments.filter { !$0.consolidated }
        guard pending.count >= 1 else { return }
        runConsolidation(of: pending, sessionTitle: inMeeting ? currentSession?.title : nil)
    }

    /// Consolidate just one session's segments (used when a meeting ends).
    private func consolidateSession(_ session: Session) {
        guard !isConsolidating, !isDeduping, !isImporting else { return }
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
                    self.applyMemoryResult(out.memories, base: snapshot)
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
                    self.maybeAutoExportTasks()
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
                    memories[i].retention = Reinforcement.boosted(memories[i].retention)  // spaced repetition (plan 17)
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
        guard !isImporting, !isConsolidating, !isDeduping else { return }
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
                    self.applyMemoryResult(out.memories, base: snapshot)
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

    // MARK: - Gmail context (plan 15)

    /// Is the Gmail integration usable (OAuth client configured in config.json)?
    var gmailConfigured: Bool { GmailService.isConfigured }

    /// Runs the OAuth consent flow in the browser and links the account.
    func connectGmail() {
        guard !gmailBusy else { return }
        guard GmailService.isConfigured else {
            statusText = GmailService.GmailError.notConfigured.localizedDescription
            return
        }
        gmailBusy = true
        statusText = "Connecting to Gmail… approve the request in your browser."
        Task {
            do {
                try await GmailService.connect()
                await MainActor.run {
                    self.gmailConnected = GmailService.isConnected
                    self.gmailAccount = GmailService.connectedAccount
                    self.gmailBusy = false
                    self.statusText = "Connected to Gmail\(self.gmailAccount.map { " (\($0))" } ?? "")."
                }
            } catch {
                await MainActor.run {
                    self.gmailBusy = false
                    self.statusText = "Gmail: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Unlinks the account locally.
    func disconnectGmail() {
        GmailService.disconnect()
        gmailConnected = false
        gmailAccount = nil
        statusText = "Disconnected Gmail."
    }

    /// Pulls recent mail and folds it into memory through the import pipeline.
    func importGmail() {
        guard !gmailBusy, !isImporting, !isConsolidating, !isDeduping else { return }
        guard GmailService.isConnected else { statusText = "Connect Gmail first."; return }
        gmailBusy = true
        isImporting = true
        statusText = "Pulling mail from Gmail…"
        let snapshot = memories
        let model = Config.memoryModel
        let query = Config.gmailQuery
        let max = Config.gmailMaxMessages
        Task {
            do {
                let messages = try await GmailService.fetchRecent(query: query, max: max) { done, total in
                    Task { @MainActor in self.statusText = "Reading mail… \(done)/\(total)" }
                }
                guard !messages.isEmpty else {
                    await MainActor.run {
                        self.gmailBusy = false; self.isImporting = false
                        self.statusText = "No mail matched the Gmail query."
                    }
                    return
                }
                let out = try await ContextImporter.importGmail(messages, into: snapshot, model: model) { done, total in
                    Task { @MainActor in self.statusText = "Distilling mail… \(done)/\(total)" }
                }
                await MainActor.run {
                    self.applyMemoryResult(out.memories, base: snapshot)
                    self.gmailBusy = false; self.isImporting = false
                    self.statusText = "Imported \(messages.count) emails: +\(out.created) new, \(out.updated) updated"
                }
            } catch {
                await MainActor.run {
                    self.gmailBusy = false; self.isImporting = false
                    self.statusText = "Gmail import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Calendar sync

    /// Reads events from the user's macOS calendars (which already sync Google/iCloud/Exchange)
    /// and folds them into memory through the import pipeline. Requests calendar access on first use.
    func syncCalendar() {
        guard !calendarBusy, !isImporting, !isConsolidating, !isDeduping else { return }
        calendarBusy = true
        isImporting = true
        statusText = "Syncing your calendar…"
        let snapshot = memories
        let model = Config.memoryModel
        let pastDays = Config.calendarImportPastDays
        let futureDays = Config.calendarImportFutureDays
        let max = Config.calendarImportMax
        let names = Config.calendarImportCalendars
        Task {
            do {
                let events = try await calendar.fetchEvents(pastDays: pastDays, futureDays: futureDays,
                                                            max: max, calendarNames: names)
                await MainActor.run { self.calendarHasAccess = CalendarService.hasAccess }
                guard !events.isEmpty else {
                    await MainActor.run {
                        self.calendarBusy = false; self.isImporting = false
                        self.statusText = "No calendar events in the sync window."
                    }
                    return
                }
                let out = try await ContextImporter.importCalendar(events, into: snapshot, model: model) { done, total in
                    Task { @MainActor in self.statusText = "Distilling events… \(done)/\(total)" }
                }
                await MainActor.run {
                    self.applyMemoryResult(out.memories, base: snapshot)
                    self.calendarBusy = false; self.isImporting = false
                    self.statusText = "Synced \(events.count) events: +\(out.created) new, \(out.updated) updated"
                }
            } catch {
                await MainActor.run {
                    self.calendarHasAccess = CalendarService.hasAccess
                    self.calendarBusy = false; self.isImporting = false
                    self.statusText = "Calendar sync failed: \(error.localizedDescription)"
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
                memories[i].retention = Reinforcement.boosted(memories[i].retention)  // spaced repetition (plan 17)
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

    /// Apply the result of an async LLM pass (consolidation / maintenance / import) without
    /// clobbering direct edits the user made to `memories` *during* the pass's await. The pass
    /// computed `result` from `base` (the snapshot at start); we reconcile by id against the
    /// current `memories`:
    ///  - user deleted a memory mid-pass (in base, gone now) → keep it deleted
    ///  - user edited a memory mid-pass (`userEdited` flipped on) → keep the user's version
    ///  - a memory added/changed concurrently that the pass never saw → preserve it
    private func applyMemoryResult(_ result: [Memory], base: [Memory]) {
        let baseIds = Set(base.map(\.id))
        let baseEditedIds = Set(base.filter { $0.userEdited }.map(\.id))
        let current = Dictionary(memories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var merged: [Memory] = []
        var used = Set<UUID>()
        for m in result {
            // Honour a delete made during the pass.
            if baseIds.contains(m.id), current[m.id] == nil { continue }
            // Honour an edit made during the pass (wasn't user-edited in the base, is now).
            if let cur = current[m.id], cur.userEdited, !baseEditedIds.contains(m.id) {
                merged.append(cur)
            } else {
                merged.append(m)
            }
            used.insert(m.id)
        }
        // Preserve memories created concurrently that the pass never saw.
        for m in memories where !used.contains(m.id) && !baseIds.contains(m.id) {
            merged.append(m)
        }
        memories = merged
        Store.saveMemories(memories)
        embeddings.sync(memories)

        // Enrich the people directory from the memories this pass created or substantively changed.
        let baseById = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let touched = memories.filter { m in
            guard let b = baseById[m.id] else { return true }   // newly created
            return b.content != m.content || b.entities != m.entities
        }
        buildPeople(touched: touched)
    }

    // MARK: - CLI resilience & usage (plans 08 / 09)

    /// A successful CLI call proves the assistant is healthy — clear any banner and reset backoff.
    private func clearAssistantHealth() {
        if assistantHealth != nil { assistantHealth = nil }
        consolidateRetries = 0
    }

    /// Classify a failed CLI call: surface hard-down states (install/login) as a persistent
    /// banner, and schedule a backoff retry for transient ones (rate limit / timeout / generic).
    private func handleAssistantFailure(_ error: Error, context: String,
                                        retriable: Bool = true, retry: @escaping () -> Void = {}) {
        guard let ae = error as? AssistantError else {
            statusText = "\(context) failed: \(error.localizedDescription)"
            return
        }
        statusText = "\(context): \(ae.localizedDescription)"
        if ae.isHardDown { assistantHealth = ae }
        guard retriable, ae.isTransient, consolidateRetries < Config.maxRetries else { return }

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
        guard Config.dedupeEnabled, !isConsolidating, !isDeduping, !isImporting, memories.count > 1 else { return }
        let snapshot = memories
        let cosine: (Int, Int) -> Double? = { i, j in self.embeddings.cosine(snapshot[i].id, snapshot[j].id) }
        let vector: (Int) -> [Double]? = { i in self.embeddings.storedVector(snapshot[i].id) }
        let pairs = Config.contradictionDetectionEnabled
            ? Consolidator.maintenancePairs(snapshot, cosine: cosine, cosineThreshold: Config.dedupeCosine, vector: vector)
            : Consolidator.candidatePairs(snapshot, cosine: cosine, cosineThreshold: Config.dedupeCosine, vector: vector)
        guard !pairs.isEmpty else { return }

        isDeduping = true
        statusText = "Tidying memory…"
        let model = Config.gateModel
        Task {
            do {
                let out = try await Consolidator.maintain(memories: snapshot, pairs: pairs, model: model)
                await MainActor.run {
                    self.applyMemoryResult(out.memories, base: snapshot)
                    self.isDeduping = false
                    self.clearAssistantHealth()
                    if out.updated > 0 { self.statusText = "Tidied memory (\(out.updated) merged/updated)" }
                }
            } catch {
                await MainActor.run {
                    self.isDeduping = false
                    self.handleAssistantFailure(error, context: "Tidy", retriable: false)
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

    // MARK: - Dream consolidation (plan 17)

    private static let lastDreamKey = "nemo.lastDream"

    /// Run a dream automatically when the app is quiet: idle (not listening), nothing else in flight,
    /// no pending segments to consolidate first, and not more often than `dreamMinHours`.
    private func maybeDream() {
        guard Config.dreamEnabled, !listening, !inMeeting,
              !isConsolidating, !isImporting, !isDeduping, !isDreaming,
              unconsolidatedCount == 0, memories.count > 1 else { return }
        if let last = UserDefaults.standard.object(forKey: Self.lastDreamKey) as? Date,
           Date().timeIntervalSince(last) < Config.dreamMinHours * 3600 { return }
        dreamNow(auto: true)
    }

    /// The dream pass: recategorize + triage fragile (episodic) memories with the cheap model, then
    /// run the pure lifecycle — promote the reinforced, decay retention, archive what's fallen below
    /// the floor, and purge long-archived memories past the grace window. `auto` distinguishes the
    /// scheduled run (records the cadence stamp) from a manual "Dream now".
    func dreamNow(auto: Bool = false) {
        guard Config.dreamEnabled, !isConsolidating, !isImporting, !isDeduping, !isDreaming,
              memories.count > 1 else { return }
        let snapshot = memories
        let model = Config.gateModel
        // Triage the fragile, low-signal memories first; cap per dream to bound cost. Most-forgettable
        // (lowest hit count, then lowest retention) go first.
        let candidates = snapshot
            .filter { $0.stage == .episodic && !$0.superseded && !$0.pinned && !$0.userEdited }
            .sorted { ($0.hitCount, $0.retention) < ($1.hitCount, $1.retention) }
            .prefix(120)

        isDreaming = true
        statusText = "Dreaming…"
        Task {
            let verdicts = await Dream.triage(Array(candidates), model: model)
            let now = Date()
            // Pure transforms on the snapshot (safe off the main actor's published state).
            let t = Dream.applyTriage(snapshot, verdicts, now: now)
            // Abstraction: distill clusters of related episodic memories into one durable gist (LLM).
            var abstracted = t.memories
            var gists = 0, subsumed = 0
            if Config.dreamAbstractEnabled {
                let clusters = Dream.entityClusters(abstracted, minSize: Config.abstractMinClusterSize)
                let abs = await Dream.abstract(clusters, from: abstracted, model: model,
                                               maxClusters: Config.abstractMaxClusters)
                let a = Dream.applyAbstractions(abstracted, abs, now: now)
                abstracted = a.memories; gists = a.created; subsumed = a.subsumed
            }
            let life = Dream.runLifecycle(abstracted, now: now,
                                          episodicHalfLife: Config.episodicHalfLifeDays,
                                          semanticHalfLife: Config.decayHalfLifeDays,
                                          retentionFloor: Config.retentionFloor,
                                          purgeGraceDays: Config.purgeGraceDays,
                                          promoteHitCount: Config.promoteHitCount)
            await MainActor.run {
                self.applyMemoryResult(life.memories, base: snapshot)
                self.isDreaming = false
                self.clearAssistantHealth()
                if auto { UserDefaults.standard.set(now, forKey: Self.lastDreamKey) }
                let recat = t.recategorized, arch = t.archived + subsumed + life.archived
                self.statusText = "Dreamt (\(gists) distilled, \(life.promoted) promoted, "
                    + "\(recat) recategorized, \(arch) archived, \(life.purged) purged)"
            }
        }
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

    // MARK: - Reminders export (plan 13)

    /// Export a memory to Apple Reminders (parsing a due date from its text if not already set).
    /// Requests access on first use; dedupes via the stored reminder id.
    func exportToReminders(_ id: UUID) {
        guard let mem = memory(id) else { return }
        Task {
            let granted = await eventKit.requestRemindersAccess()
            guard granted else {
                await MainActor.run { self.statusText = "Reminders access denied" }
                return
            }
            // Resolve (and persist) a due date if we don't have one yet.
            var m = mem
            if m.due == nil { m.due = DateExtractor.firstDate(in: m.title + " " + m.content) }
            do {
                let rid = try self.eventKit.exportReminder(memory: m, listName: Config.remindersListName)
                await MainActor.run {
                    if let i = self.memories.firstIndex(where: { $0.id == id }) {
                        self.memories[i].exportedReminderId = rid
                        self.memories[i].due = m.due
                        Store.saveMemories(self.memories)
                    }
                    self.statusText = "Added to Reminders: \(mem.title)"
                }
            } catch {
                await MainActor.run { self.statusText = "Reminders export failed: \(error.localizedDescription)" }
            }
        }
    }

    /// After consolidation, optionally push new dated action items to Reminders (opt-in, capped).
    /// Runs as a single serialized task — one access request, sequential saves — so it can't
    /// race EKEventStore or create duplicate "Nemo" lists.
    private func maybeAutoExportTasks() {
        guard Config.calendarExportEnabled, Config.autoExportTasks else { return }
        let candidateIds = liveMemories.filter {
            $0.categoryEnum == .tasks && $0.exportedReminderId == nil
                && DateExtractor.firstDate(in: $0.title + " " + $0.content) != nil
        }.prefix(10).map(\.id)
        guard !candidateIds.isEmpty else { return }
        let listName = Config.remindersListName
        Task {
            guard await eventKit.requestRemindersAccess() else { return }
            for id in candidateIds {
                guard var m = self.memory(id) else { continue }
                if m.due == nil { m.due = DateExtractor.firstDate(in: m.title + " " + m.content) }
                guard let rid = try? self.eventKit.exportReminder(memory: m, listName: listName) else { continue }
                if let i = self.memories.firstIndex(where: { $0.id == id }) {
                    self.memories[i].exportedReminderId = rid
                    self.memories[i].due = m.due
                }
            }
            Store.saveMemories(self.memories)
        }
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

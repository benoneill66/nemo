import Foundation

/// Typed view over ~/.config/nemo/config.json for the always-listening features.
/// Everything has a sensible default so the app works with no config file at all.
enum Config {
    private static func raw() -> [String: Any] { Settings.raw() }

    private static func strings(_ key: String, default def: [String]) -> [String] {
        (raw()[key] as? [String])?.map { $0.lowercased() }.filter { !$0.isEmpty } ?? def
    }

    /// Spoken phrases that flag the surrounding speech as important.
    static var markers: [String] {
        strings("markers", default: [
            "important", "remember this", "remember that", "make a note", "note that",
            "note to self", "action item", "don't forget", "flag this", "mark this",
            "key point", "takeaway", "follow up"
        ])
    }

    /// Phrases that open / close a named meeting session.
    static var meetingStartPhrases: [String] {
        strings("meetingStart", default: ["start meeting", "begin meeting", "start a meeting", "start recording meeting"])
    }
    static var meetingStopPhrases: [String] {
        strings("meetingStop", default: ["end meeting", "stop meeting", "end the meeting", "finish meeting", "wrap up meeting"])
    }

    /// Optional wake phrases ("hey <word>") that route the spoken question to Claude and
    /// answer aloud. Set "wakeAnswer": false in config.json to disable the talk-back feature.
    static var wakeAnswerEnabled: Bool { (raw()["wakeAnswer"] as? Bool) ?? true }
    static var wakeWords: [String] {
        strings("wakeWords", default: ["nemo", "nimo", "neemo", "nemmo", "memo"])
    }

    /// How the consolidator is scheduled.
    static var consolidateMinutes: Double { (raw()["consolidateMinutes"] as? Double) ?? 5 }
    static var consolidateMinSegments: Int { (raw()["consolidateMinSegments"] as? Int) ?? 6 }

    /// Real-time surfacing: bring up memories relevant to what's being said, as it's said.
    /// All on-device, no LLM call. Set "surface": false to disable.
    static var surfaceEnabled: Bool { (raw()["surface"] as? Bool) ?? true }
    /// How many seconds of recent speech are considered "the current moment".
    static var surfaceWindowSeconds: Double { (raw()["surfaceWindowSeconds"] as? Double) ?? 45 }
    /// How long a surfaced card lingers after its last match before fading out.
    static var surfaceTTLSeconds: Double { (raw()["surfaceTTLSeconds"] as? Double) ?? 90 }
    /// Most cards shown at once.
    static var surfaceMax: Int { (raw()["surfaceMax"] as? Int) ?? 4 }
    /// Relevance score a memory must clear to surface (higher = stricter).
    static var surfaceMinScore: Double { (raw()["surfaceMinScore"] as? Double) ?? 3.0 }

    /// Morning briefing: on launch, distill open items + recent sessions into a short daily
    /// catch-up (once per day, cached). Set "briefing": false to disable.
    static var briefingEnabled: Bool { (raw()["briefing"] as? Bool) ?? true }
    /// Read the briefing aloud automatically when it's generated. Off by default — it shows
    /// as a card you can tap to hear.
    static var briefingSpeak: Bool { (raw()["briefingSpeak"] as? Bool) ?? false }

    /// Model used for memory consolidation / import (kept fast + cheap by default).
    static var memoryModel: String? { (raw()["memoryModel"] as? String) ?? "claude-sonnet-4-6" }

    /// Cheap, fast model for the relevance gate that runs *before* consolidation: it decides
    /// which raw segments are worth remembering so we only spend the expensive model on those
    /// (and never call it at all on a batch of pure chit-chat). Defaults to Haiku.
    static var gateModel: String? { (raw()["gateModel"] as? String) ?? "claude-haiku-4-5" }
    /// Whether the pre-consolidation relevance gate runs. Off → every segment is consolidated
    /// (the old behaviour). Set "relevanceGate": false in config.json to disable.
    static var relevanceGateEnabled: Bool { (raw()["relevanceGate"] as? Bool) ?? true }

    /// How many days to keep raw transcript segments after they've been consolidated. Older
    /// consolidated segments are pruned to bound disk growth; user-marked segments and meeting
    /// transcripts are always kept. 0 disables pruning.
    static var transcriptRetentionDays: Int { (raw()["transcriptRetentionDays"] as? Int) ?? 7 }

    /// Extra files/dirs of existing assistant memory to offer for import, beyond the
    /// auto-discovered Claude locations.
    static var importPaths: [String] {
        (raw()["importPaths"] as? [String]) ?? []
    }

    /// Speaker diarization: tell apart distinct voices in the transcript using on-device acoustic
    /// fingerprints (MFCC + pitch), labelling segments "Speaker 1/2/…" (renameable). All local —
    /// no audio leaves the Mac. Set "diarization": false in config.json to disable.
    static var diarizationEnabled: Bool { (raw()["diarization"] as? Bool) ?? true }
    /// How readily two voices are considered the same person. Higher = more lenient (collapses
    /// speakers together); lower = splits more eagerly. ~1.5 is a reasonable middle.
    static var speakerThreshold: Double { (raw()["speakerThreshold"] as? Double) ?? 1.5 }

    /// Transcription backend: "auto" (prefer enhanced dictation on macOS 26+), "dictation",
    /// or "legacy" (force the SFSpeechRecognizer path).
    static var engine: String { ((raw()["engine"] as? String) ?? "auto").lowercased() }

    /// Locale for transcription, e.g. "en-GB". Defaults to the system locale.
    static var locale: Locale? {
        guard let id = raw()["locale"] as? String, !id.isEmpty else { return nil }
        return Locale(identifier: id)
    }

    static var voice: String? { raw()["voice"] as? String }
    static var rate: Double? { raw()["rate"] as? Double }
    static var chime: Any? { raw()["chime"] }

    private static func bool(_ key: String, default def: Bool) -> Bool { (raw()[key] as? Bool) ?? def }
    private static func double(_ key: String, default def: Double) -> Double { (raw()[key] as? Double) ?? def }
    private static func int(_ key: String, default def: Int) -> Int { (raw()[key] as? Int) ?? def }

    // MARK: - Semantic surfacing (plan 01)
    /// Blend on-device sentence embeddings into the live relevance engine. Set false → lexical only.
    static var semanticSurfaceEnabled: Bool { bool("semanticSurface", default: true) }
    /// How strongly semantic similarity counts relative to lexical hits.
    static var semanticWeight: Double { double("semanticWeight", default: 4.0) }
    /// Minimum cosine similarity for a semantic neighbour to count at all.
    static var semanticFloor: Double { double("semanticFloor", default: 0.30) }

    // MARK: - Reinforcement / decay (plan 02)
    static var reinforcementEnabled: Bool { bool("reinforcement", default: true) }
    static var decayHalfLifeDays: Double { double("decayHalfLifeDays", default: 30) }

    // MARK: - Dedup (plan 03)
    static var dedupeEnabled: Bool { bool("dedupe", default: true) }
    static var dedupeEveryNNew: Int { int("dedupeEveryNNew", default: 25) }
    static var dedupeCosine: Double { double("dedupeCosine", default: 0.82) }

    // MARK: - Contradiction detection (plan 04)
    static var contradictionDetectionEnabled: Bool { bool("contradictionDetection", default: true) }

    // MARK: - Privacy controls (plan 06)
    static var redactionEnabled: Bool { bool("redaction", default: true) }
    static var excludedApps: [String] { (raw()["excludedApps"] as? [String]) ?? [] }
    static var pausePhrases: [String] {
        strings("pausePhrases", default: ["pause listening", "stop recording", "pause nemo"])
    }
    static var resumePhrases: [String] {
        strings("resumePhrases", default: ["resume listening", "start recording again", "resume nemo"])
    }

    // MARK: - Usage tracking (plan 09)
    static var usageTrackingEnabled: Bool { bool("usageTracking", default: true) }
    static var usageRetentionDays: Int { int("usageRetentionDays", default: 30) }

    // MARK: - CLI resilience (plan 08)
    static var maxRetries: Int { int("maxRetries", default: 4) }
    static var retryBackoffSeconds: Double { double("retryBackoffSeconds", default: 30) }

    // MARK: - Retrieval-augmented answers (plan 11)
    static var memoryGroundedAnswers: Bool { bool("memoryGroundedAnswers", default: true) }
    static var answerMemoryK: Int { int("answerMemoryK", default: 6) }

    // MARK: - Calendar / Reminders export (plan 13)
    static var calendarExportEnabled: Bool { bool("calendarExport", default: false) }
    static var autoExportTasks: Bool { bool("autoExportTasks", default: false) }
    static var remindersListName: String { (raw()["remindersListName"] as? String) ?? "Nemo" }

    // MARK: - Calendar import (sync events into memory)
    /// How far back / forward (in days) a calendar sync reads events from the user's macOS calendars,
    /// the per-sync event cap, and an optional whitelist of calendar names (empty = all calendars).
    static var calendarImportPastDays: Int { int("calendarImportPastDays", default: 7) }
    static var calendarImportFutureDays: Int { int("calendarImportFutureDays", default: 30) }
    static var calendarImportMax: Int { int("calendarImportMax", default: 100) }
    static var calendarImportCalendars: [String] { (raw()["calendarImportCalendars"] as? [String]) ?? [] }

    // MARK: - MCP server (plan 12)
    static var mcpEnabled: Bool { bool("mcp", default: true) }
    static var mcpAllowWrite: Bool { bool("mcpAllowWrite", default: false) }

    // MARK: - Floating overlay (plan 14)
    /// Show a persistent floating "listening" bar (Wispr-style) while Nemo is capturing.
    /// Set "overlay": false in config.json to disable it entirely.
    static var overlayEnabled: Bool { bool("overlay", default: true) }
    /// Keep the bar on screen the whole time the app is open (idle bar shows "Idle"),
    /// instead of only while listening. Set "overlayAlwaysVisible": false to hide when idle.
    static var overlayAlwaysVisible: Bool { bool("overlayAlwaysVisible", default: true) }

    // MARK: - Gmail context import (plan 15)
    /// OAuth client for the Gmail integration. Resolution order:
    ///   1. config.json `gmail.clientId` / `gmail.clientSecret`
    ///   2. GMAIL_CLIENT_ID / GMAIL_CLIENT_SECRET environment variables
    ///   3. the `gog` CLI's stored OAuth client (a Desktop client whose loopback redirect we can
    ///      reuse), so anyone already signed into gog gets Gmail import with zero setup.
    static var gmailClientId: String? {
        (gmail["clientId"] as? String)
            ?? ProcessInfo.processInfo.environment["GMAIL_CLIENT_ID"]
            ?? gogClient()?.id
    }
    static var gmailClientSecret: String? {
        (gmail["clientSecret"] as? String)
            ?? ProcessInfo.processInfo.environment["GMAIL_CLIENT_SECRET"]
            ?? gogClient()?.secret
    }

    /// Reads the `gog` CLI's stored OAuth client (`~/Library/Application Support/gogcli/
    /// credentials.json`). Supports gog's flat shape as well as Google's `installed` / `web`
    /// wrappers. Returns nil if gog isn't set up.
    private static func gogClient() -> (id: String, secret: String)? {
        let path = ("~/Library/Application Support/gogcli/credentials.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let root = (json["installed"] as? [String: Any]) ?? (json["web"] as? [String: Any]) ?? json
        guard let id = root["client_id"] as? String, !id.isEmpty,
              let secret = root["client_secret"] as? String, !secret.isEmpty else { return nil }
        return (id, secret)
    }
    /// Gmail search query bounding what gets pulled (Gmail search syntax). Defaults to recent,
    /// non-promotional primary mail.
    static var gmailQuery: String {
        (gmail["query"] as? String) ?? "newer_than:30d -category:promotions -category:social"
    }
    /// Cap on how many messages a single pull imports.
    static var gmailMaxMessages: Int { (gmail["maxMessages"] as? Int) ?? 50 }
    private static var gmail: [String: Any] { (raw()["gmail"] as? [String: Any]) ?? [:] }

    // MARK: - Dream consolidation: tiers, forgetting & abstraction (plan 17)
    /// Master switch for the human-memory model (episodic→semantic tiers, forgetting curve, the
    /// periodic "dream" consolidation pass). Off → memories behave as before plan 17.
    static var dreamEnabled: Bool { bool("dream", default: true) }
    /// Minimum hours between automatic dreams.
    static var dreamMinHours: Double { double("dreamMinHours", default: 12) }
    /// How long the app must be idle (not capturing) before an automatic dream may run.
    static var dreamIdleMinutes: Double { double("dreamIdleMinutes", default: 20) }
    /// Retention strength below which an episodic memory is archived (forgotten). 0 disables forgetting.
    static var retentionFloor: Double { double("retentionFloor", default: 0.15) }
    /// Days an archived memory lingers (restorable) before it's eligible for hard purge. 0 disables purge.
    static var purgeGraceDays: Int { int("purgeGraceDays", default: 90) }
    /// Fast forgetting half-life for fresh/imported episodic memories (semantic memories use the
    /// slower `decayHalfLifeDays`).
    static var episodicHalfLifeDays: Double { double("episodicHalfLifeDays", default: 10) }
    /// Surfacing hits at/above which an episodic memory is promoted to semantic (durable).
    static var promoteHitCount: Int { int("promoteHitCount", default: 3) }
    /// Abstraction (cluster→gist): distill clusters of related episodic memories into one durable
    /// semantic memory, archiving the subsumed specifics. Set false to keep dreams to recategorize+forget.
    static var dreamAbstractEnabled: Bool { bool("dreamAbstract", default: true) }
    /// Smallest entity cluster worth abstracting into a gist.
    static var abstractMinClusterSize: Int { int("abstractMinClusterSize", default: 4) }
    /// Most clusters abstracted per dream (bounds cost).
    static var abstractMaxClusters: Int { int("abstractMaxClusters", default: 6) }

    // MARK: - People directory (plan 16)
    /// Build a first-class people directory from consolidated memories: extract people, accumulate
    /// context about them over time, and disambiguate same-named people using prior context.
    /// Set "people": false in config.json to disable the LLM enrichment pass (the directory then
    /// only grows from named speakers and manual edits).
    static var peopleEnabled: Bool { bool("people", default: true) }
}

import Foundation

/// On-disk persistence for transcripts, memories, and sessions. Everything lives under
/// ~/.config/nemo/data so it sits alongside the existing config.json.
enum Store {
    /// Moves a pre-rename ~/.config/hey-claude directory to ~/.config/nemo so existing
    /// config + memories survive the rename. Runs once, before any path is read.
    static func migrateLegacyConfigIfNeeded() {
        let fm = FileManager.default
        let old = ("~/.config/hey-claude" as NSString).expandingTildeInPath
        let new = ("~/.config/nemo" as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: old), !fm.fileExists(atPath: new) else { return }
        try? fm.moveItem(atPath: old, toPath: new)
    }

    static let dir: URL = {
        let base = ("~/.config/nemo/data" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: base, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static var segmentsURL: URL { dir.appendingPathComponent("transcript.json") }
    private static var memoriesURL: URL { dir.appendingPathComponent("memories.json") }
    private static var sessionsURL: URL { dir.appendingPathComponent("sessions.json") }
    private static var briefingURL: URL { dir.appendingPathComponent("briefing.json") }
    private static var speakersURL: URL { dir.appendingPathComponent("speakers.json") }
    private static var embeddingsURL: URL { dir.appendingPathComponent("embeddings.json") }
    private static var usageURL: URL { dir.appendingPathComponent("usage.json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func load<T: Decodable>(_ url: URL, _ type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    /// Atomic write off the main thread.
    private static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func loadSegments() -> [TranscriptSegment] { load(segmentsURL, [TranscriptSegment].self) ?? [] }
    static func loadMemories() -> [Memory] { load(memoriesURL, [Memory].self) ?? [] }
    static func loadSessions() -> [Session] { load(sessionsURL, [Session].self) ?? [] }

    static func loadBriefing() -> Briefing? { load(briefingURL, Briefing.self) }
    static func loadSpeakers() -> [SpeakerIdentity] { load(speakersURL, [SpeakerIdentity].self) ?? [] }

    static func saveSegments(_ v: [TranscriptSegment]) { save(v, to: segmentsURL) }
    static func saveMemories(_ v: [Memory]) { save(v, to: memoriesURL) }
    static func saveSessions(_ v: [Session]) { save(v, to: sessionsURL) }
    static func saveBriefing(_ v: Briefing) { save(v, to: briefingURL) }
    static func saveSpeakers(_ v: [SpeakerIdentity]) { save(v, to: speakersURL) }

    // Semantic embedding cache (plan 01) — safe to delete; rebuilds on next sync.
    static func loadEmbeddingCache() -> EmbeddingCache? { load(embeddingsURL, EmbeddingCache.self) }
    static func saveEmbeddingCache(_ v: EmbeddingCache) { save(v, to: embeddingsURL) }

    // LLM usage log (plan 09) — metadata only, never prompt/response text.
    static func loadUsage() -> [UsageEvent] { load(usageURL, [UsageEvent].self) ?? [] }
    static func saveUsage(_ v: [UsageEvent]) { save(v, to: usageURL) }
}

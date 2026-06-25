import Foundation

/// SQLite-backed persistence for the two unbounded tables — memories and transcript segments
/// (plan 10, hybrid approach). Each row stores the model's full JSON in a `data` column (so
/// round-trips are exact) plus a few mirrored columns for indexed queries, and an FTS5 table over
/// transcript text. Opt-in via `Config.storageBackend == "sqlite"`; JSON remains the default and,
/// in SQLite mode, is still written as a backup so rollback is trivial.
final class SQLiteStore {
    private let db: SQLiteDB
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init?(path: String) {
        guard let db = SQLiteDB(path: path) else { return nil }
        self.db = db
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; self.encoder = e
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; self.decoder = d
        migrate()
    }

    private func migrate() {
        db.exec("""
        CREATE TABLE IF NOT EXISTS memories(
          id TEXT PRIMARY KEY, data TEXT NOT NULL, category TEXT, updated TEXT, superseded INTEGER);
        """)
        db.exec("CREATE INDEX IF NOT EXISTS idx_mem_cat ON memories(category);")
        db.exec("CREATE INDEX IF NOT EXISTS idx_mem_sup ON memories(superseded);")
        db.exec("""
        CREATE TABLE IF NOT EXISTS segments(
          id TEXT PRIMARY KEY, data TEXT NOT NULL, end TEXT, consolidated INTEGER, session TEXT, marked INTEGER);
        """)
        db.exec("CREATE INDEX IF NOT EXISTS idx_seg_session ON segments(session);")
        db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(id UNINDEXED, text);")
    }

    // MARK: - Memories

    var memoryCount: Int { Int(db.query("SELECT COUNT(*) FROM memories;").first?.first.flatMap { $0 } ?? "0") ?? 0 }

    func loadMemories() -> [Memory] {
        db.query("SELECT data FROM memories;").compactMap { row in
            row.first.flatMap { $0 }.flatMap { $0.data(using: .utf8) }.flatMap { try? decoder.decode(Memory.self, from: $0) }
        }
    }

    func saveMemories(_ memories: [Memory]) {
        db.transaction {
            db.exec("DELETE FROM memories;")
            for m in memories {
                guard let data = try? encoder.encode(m), let json = String(data: data, encoding: .utf8) else { continue }
                db.run("INSERT OR REPLACE INTO memories(id, data, category, updated, superseded) VALUES(?,?,?,?,?);",
                       [m.id.uuidString, json, m.category, iso(m.updated), m.superseded ? "1" : "0"])
            }
        }
    }

    // MARK: - Segments

    func loadSegments() -> [TranscriptSegment] {
        db.query("SELECT data FROM segments;").compactMap { row in
            row.first.flatMap { $0 }.flatMap { $0.data(using: .utf8) }.flatMap { try? decoder.decode(TranscriptSegment.self, from: $0) }
        }
    }

    func saveSegments(_ segments: [TranscriptSegment]) {
        db.transaction {
            db.exec("DELETE FROM segments;")
            db.exec("DELETE FROM segments_fts;")
            for s in segments {
                guard let data = try? encoder.encode(s), let json = String(data: data, encoding: .utf8) else { continue }
                db.run("INSERT OR REPLACE INTO segments(id, data, end, consolidated, session, marked) VALUES(?,?,?,?,?,?);",
                       [s.id.uuidString, json, iso(s.end), s.consolidated ? "1" : "0",
                        s.sessionId?.uuidString, s.marked ? "1" : "0"])
                db.run("INSERT INTO segments_fts(id, text) VALUES(?,?);", [s.id.uuidString, s.text])
            }
        }
    }

    /// Full-text search over retained transcript, returning matching segment ids (plan 10/12).
    func searchTranscript(_ query: String, limit: Int = 20) -> [UUID] {
        let q = query.replacingOccurrences(of: "\"", with: " ")
        return db.query("SELECT id FROM segments_fts WHERE text MATCH ? LIMIT ?;",
                        ["\"\(q)\"", String(limit)])
            .compactMap { $0.first.flatMap { $0 }.flatMap(UUID.init) }
    }

    /// One-time import from the JSON store when first switching to SQLite (keeps JSON as backup).
    func migrateFromJSONIfEmpty(memories: [Memory], segments: [TranscriptSegment]) {
        if memoryCount == 0, !memories.isEmpty { saveMemories(memories) }
        let segCount = Int(db.query("SELECT COUNT(*) FROM segments;").first?.first.flatMap { $0 } ?? "0") ?? 0
        if segCount == 0, !segments.isEmpty { saveSegments(segments) }
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

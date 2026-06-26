import Foundation

/// SQLite-backed persistence for the two unbounded tables — memories and transcript segments
/// (plan 10). Each row stores the model's full JSON in a `data` column (so round-trips are exact)
/// plus a few mirrored columns for indexed queries, and an FTS5 table over transcript text. This is
/// the sole backend for these two tables; the legacy JSON files are read once to seed the DB on
/// upgrade (`migrateFromJSONIfEmpty`) and then left frozen as a backup. Saves write only the delta.
final class SQLiteStore {
    private let db: SQLiteDB
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // Last-saved snapshots so each save writes only the delta (changed/new/removed rows) instead of
    // rewriting every row (plan 10). nil = not yet seeded; seeded lazily from the DB on first use so
    // deletions are correct regardless of whether `load…` ran first.
    private var memSnapshot: [UUID: Memory]?
    private var segSnapshot: [UUID: TranscriptSegment]?

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
        let memories = db.query("SELECT data FROM memories;").compactMap { row in
            row.first.flatMap { $0 }.flatMap { $0.data(using: .utf8) }.flatMap { try? decoder.decode(Memory.self, from: $0) }
        }
        memSnapshot = Dictionary(memories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return memories
    }

    /// Persist `memories` by writing only the delta against the last-saved snapshot: upsert new and
    /// changed rows, delete removed ones. The DB still ends up exactly equal to `memories`, but a
    /// save now costs O(changes) JSON-encodes + writes instead of re-encoding and rewriting all rows.
    func saveMemories(_ memories: [Memory]) {
        let prior = memSnapshot ?? loadMemories().reduce(into: [:]) { $0[$1.id] = $1 }
        let nextIds = Set(memories.map(\.id))
        db.transaction {
            for id in prior.keys where !nextIds.contains(id) {
                db.run("DELETE FROM memories WHERE id=?;", [id.uuidString])
            }
            for m in memories where prior[m.id] != m {   // new or changed only
                guard let data = try? encoder.encode(m), let json = String(data: data, encoding: .utf8) else { continue }
                db.run("INSERT OR REPLACE INTO memories(id, data, category, updated, superseded) VALUES(?,?,?,?,?);",
                       [m.id.uuidString, json, m.category, iso(m.updated), m.superseded ? "1" : "0"])
            }
        }
        memSnapshot = Dictionary(memories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Segments

    func loadSegments() -> [TranscriptSegment] {
        let segments = db.query("SELECT data FROM segments;").compactMap { row in
            row.first.flatMap { $0 }.flatMap { $0.data(using: .utf8) }.flatMap { try? decoder.decode(TranscriptSegment.self, from: $0) }
        }
        segSnapshot = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return segments
    }

    /// Persist `segments` as a delta against the last save (upsert changed/new, delete removed). The
    /// FTS row is only rewritten when a segment's `text` changes — text is immutable once captured,
    /// so the common case (flipping `consolidated`/`marked`, appending new segments) touches FTS
    /// minimally instead of rebuilding the whole index every save.
    func saveSegments(_ segments: [TranscriptSegment]) {
        let prior = segSnapshot ?? loadSegments().reduce(into: [:]) { $0[$1.id] = $1 }
        let nextIds = Set(segments.map(\.id))
        db.transaction {
            for id in prior.keys where !nextIds.contains(id) {
                db.run("DELETE FROM segments WHERE id=?;", [id.uuidString])
                db.run("DELETE FROM segments_fts WHERE id=?;", [id.uuidString])
            }
            for s in segments {
                let before = prior[s.id]
                guard before != s else { continue }   // unchanged
                guard let data = try? encoder.encode(s), let json = String(data: data, encoding: .utf8) else { continue }
                db.run("INSERT OR REPLACE INTO segments(id, data, end, consolidated, session, marked) VALUES(?,?,?,?,?,?);",
                       [s.id.uuidString, json, iso(s.end), s.consolidated ? "1" : "0",
                        s.sessionId?.uuidString, s.marked ? "1" : "0"])
                if before?.text != s.text {            // FTS only when the searchable text changes
                    db.run("DELETE FROM segments_fts WHERE id=?;", [s.id.uuidString])
                    db.run("INSERT INTO segments_fts(id, text) VALUES(?,?);", [s.id.uuidString, s.text])
                }
            }
        }
        segSnapshot = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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

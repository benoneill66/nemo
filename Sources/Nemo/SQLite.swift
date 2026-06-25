import Foundation
import SQLite3

/// A tiny, dependency-free wrapper over the system `libsqlite3` (plan 10). Just enough to run
/// statements and read text rows — no ORM, consistent with Nemo's "Apple frameworks only" ethos.
/// Single-connection, used on a serial queue by `SQLiteStore`.
final class SQLiteDB {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(path: String) {
        guard sqlite3_open(path, &db) == SQLITE_OK else { sqlite3_close(db); return nil }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
    }
    deinit { sqlite3_close(db) }

    @discardableResult
    func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    /// Run a parameterized statement with 1-based text binds (nil → NULL).
    func run(_ sql: String, _ binds: [String?] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        _ = sqlite3_step(stmt)
    }

    /// Query returning rows of optional text columns.
    func query(_ sql: String, _ binds: [String?] = []) -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        var rows: [[String?]] = []
        let cols = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String?] = []
            for c in 0..<cols {
                if let cstr = sqlite3_column_text(stmt, c) { row.append(String(cString: cstr)) }
                else { row.append(nil) }
            }
            rows.append(row)
        }
        return rows
    }

    func transaction(_ body: () -> Void) {
        exec("BEGIN"); body(); exec("COMMIT")
    }

    private func bind(_ stmt: OpaquePointer?, _ binds: [String?]) {
        for (i, v) in binds.enumerated() {
            if let v { sqlite3_bind_text(stmt, Int32(i + 1), v, -1, Self.transient) }
            else { sqlite3_bind_null(stmt, Int32(i + 1)) }
        }
    }
}

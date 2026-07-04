import Foundation

/// Persists the delta-sync high-water marks (`updatedSince` / `lastUpdate`
/// values). With a persistent implementation, a cold launch resumes from the
/// last-seen server timestamps instead of a full re-sync — the piece that
/// makes the offline cache pay off.
public protocol SyncMarkStoring: Sendable {
    func mark(for key: String) async -> Date?
    func set(_ date: Date, for key: String) async
    func clear() async
}

actor InMemorySyncMarkStore: SyncMarkStoring {
    private var marks: [String: Date] = [:]

    func mark(for key: String) -> Date? {
        marks[key]
    }

    func set(_ date: Date, for key: String) {
        marks[key] = date
    }

    func clear() {
        marks = [:]
    }
}

actor SQLiteSyncMarkStore: SyncMarkStoring {
    private let database: SQLiteDatabase

    init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS sync_marks (
                key TEXT PRIMARY KEY,
                ts REAL NOT NULL
            )
            """)
    }

    func mark(for key: String) -> Date? {
        let rows = try? database.query(
            "SELECT ts FROM sync_marks WHERE key = ?", [.text(key)]
        ) { column in column(0).realValue }
        guard let timestamp = rows?.first ?? nil else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func set(_ date: Date, for key: String) {
        try? database.run(
            "INSERT INTO sync_marks (key, ts) VALUES (?, ?) "
            + "ON CONFLICT(key) DO UPDATE SET ts = excluded.ts",
            [.text(key), .real(date.timeIntervalSince1970)])
    }

    func clear() {
        try? database.run("DELETE FROM sync_marks")
    }
}

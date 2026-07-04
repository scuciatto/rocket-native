import Foundation
import SQLite3

/// Minimal wrapper over the system SQLite3 C API — deliberately not a full
/// ORM, keeping the SDK dependency-free. Not thread-safe by itself: each
/// persistent store actor owns its own connection to the shared database
/// file; cross-connection coordination is WAL + busy_timeout.
final class SQLiteDatabase {
    enum Value {
        case text(String)
        case real(Double)
        case int(Int64)
        case null
    }

    struct SQLiteError: Error, CustomStringConvertible {
        let message: String
        var description: String { "SQLite: \(message)" }
    }

    private var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(
            path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(message: message)
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA busy_timeout=3000")
        try execute("PRAGMA synchronous=NORMAL")
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Runs statements that take no bindings (DDL, pragmas).
    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorMessage)
            throw SQLiteError(message: message)
        }
    }

    /// Runs one bound statement, discarding any rows.
    func run(_ sql: String, _ bindings: [Value] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// Runs a query, mapping each row through `row`.
    func query<T>(
        _ sql: String, _ bindings: [Value] = [],
        row: (_ column: (Int32) -> Value) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
            }
            results.append(try row { index in
                switch sqlite3_column_type(statement, index) {
                case SQLITE_TEXT:
                    return .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_FLOAT:
                    return .real(sqlite3_column_double(statement, index))
                case SQLITE_INTEGER:
                    return .int(sqlite3_column_int64(statement, index))
                default:
                    return .null
                }
            })
        }
        return results
    }

    private func prepare(_ sql: String, _ bindings: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let string):
                sqlite3_bind_text(statement, index, string, -1, transient)
            case .real(let double):
                sqlite3_bind_double(statement, index, double)
            case .int(let integer):
                sqlite3_bind_int64(statement, index, integer)
            case .null:
                sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
}

extension SQLiteDatabase.Value {
    var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var realValue: Double? {
        switch self {
        case .real(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .real(let value): return Int64(value)
        default: return nil
        }
    }
}

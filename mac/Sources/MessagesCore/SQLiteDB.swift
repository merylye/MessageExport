import Foundation
import SQLite3

public enum SQLiteError: Error, LocalizedError {
    case open(String)
    case query(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): return "Could not open the database: \(message)"
        case .query(let message): return "Database query failed: \(message)"
        }
    }
}

public enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal wrapper around the system SQLite library.
public final class SQLiteDB {
    private var handle: OpaquePointer?

    public init(path: String, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(rc)"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError.open(message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw SQLiteError.query(message)
        }
    }

    public func query(_ sql: String, _ params: [SQLValue] = [], row: (SQLRow) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            throw SQLiteError.query(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .double(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                _ = v.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                }
            case .null: sqlite3_bind_null(statement, index)
            }
        }

        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                try row(SQLRow(stmt: statement))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.query(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    public func run(_ sql: String, _ params: [SQLValue] = []) throws {
        try query(sql, params) { _ in }
    }

    public func tableExists(_ table: String) -> Bool {
        var found = false
        try? query("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [.text(table)]) { _ in found = true }
        return found
    }

    public func columns(of table: String) -> Set<String> {
        var names = Set<String>()
        try? query("PRAGMA table_info(\(table))") { row in
            if let name = row.text(1) { names.insert(name) }
        }
        return names
    }
}

public struct SQLRow {
    let stmt: OpaquePointer

    public func isNull(_ i: Int32) -> Bool {
        sqlite3_column_type(stmt, i) == SQLITE_NULL
    }

    public func int(_ i: Int32) -> Int64 {
        sqlite3_column_int64(stmt, i)
    }

    public func optionalInt(_ i: Int32) -> Int64? {
        isNull(i) ? nil : sqlite3_column_int64(stmt, i)
    }

    public func text(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    public func blob(_ i: Int32) -> Data? {
        guard !isNull(i), let pointer = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}

import Foundation
import SQLite3

/// Failure reported by SQLite, or a file that is not usable as a history database.
enum SQLiteError: Error, CustomStringConvertible {
    case failed(code: Int32, message: String)
    case incompatibleSchema(version: Int)

    /// The file is damaged or not a database at all.
    var needsReplacement: Bool {
        switch self {
        case .failed(let code, _):
            let primary = code & 0xFF
            return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
        case .incompatibleSchema:
            return true
        }
    }

    var description: String {
        switch self {
        case .failed(let code, let message): "SQLite \(code): \(message)"
        case .incompatibleSchema(let version): "Incompatible schema version \(version)"
        }
    }
}

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper over one `sqlite3` handle. Not thread-safe; owned by the `HistoryStore` actor.
final class SQLiteDatabase {
    private(set) var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(handle)
            // The failed init still runs `deinit`: without this it would close the same handle a second time.
            handle = nil
            throw SQLiteError.failed(code: code, message: message)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { if handle != nil { sqlite3_close_v2(handle) } }

    func error(_ code: Int32) -> SQLiteError {
        .failed(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    func exec(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw error(code) }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var stmt: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard code == SQLITE_OK, let stmt else { throw error(code) }
        return SQLiteStatement(stmt: stmt, database: self)
    }

    /// Runs `body` inside one write transaction; rolls back when it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }
}

final class SQLiteStatement {
    private let stmt: OpaquePointer
    private let database: SQLiteDatabase

    init(stmt: OpaquePointer, database: SQLiteDatabase) {
        self.stmt = stmt
        self.database = database
    }

    deinit { sqlite3_finalize(stmt) }

    private func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .int(let v): code = sqlite3_bind_int64(stmt, index, v)
            case .double(let v): code = sqlite3_bind_double(stmt, index, v)
            case .text(let v): code = sqlite3_bind_text(stmt, index, v, -1, transient)
            case .null: code = sqlite3_bind_null(stmt, index)
            }
            guard code == SQLITE_OK else { throw database.error(code) }
        }
    }

    /// Executes a statement that returns no rows.
    func run(_ values: [SQLValue] = []) throws {
        try bind(values)
        let code = sqlite3_step(stmt)
        sqlite3_reset(stmt)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw database.error(code) }
    }

    /// Calls `body` for every result row.
    func forEachRow(_ values: [SQLValue] = [], _ body: (SQLiteStatement) -> Void) throws {
        try bind(values)
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_ROW {
                body(self)
            } else if code == SQLITE_DONE {
                break
            } else {
                sqlite3_reset(stmt)
                throw database.error(code)
            }
        }
        sqlite3_reset(stmt)
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(stmt, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(stmt, column) }
    func text(_ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }
    func optionalText(_ column: Int32) -> String? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : text(column)
    }
}

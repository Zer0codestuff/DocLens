import Foundation
import SQLite3

public enum SQLValue: Sendable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public var code: Int32
    public var message: String
    public var sql: String?
    public var description: String { "SQLite error \(code): \(message)" + (sql.map { " in \($0.prefix(120))" } ?? "") }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteStatement {
    let handle: OpaquePointer
    let sql: String

    init(handle: OpaquePointer, sql: String) {
        self.handle = handle
        self.sql = sql
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [SQLValue]) {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .null: sqlite3_bind_null(handle, idx)
            case .int(let n): sqlite3_bind_int64(handle, idx, n)
            case .double(let d): sqlite3_bind_double(handle, idx, d)
            case .text(let s): sqlite3_bind_text(handle, idx, s, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            case .blob(let data):
                data.withUnsafeBytes { buf in
                    _ = sqlite3_bind_blob(handle, idx, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT_DESTRUCTOR)
                }
            }
        }
    }

    public func string(_ column: Int32) -> String? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL, let c = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: c)
    }

    public func int(_ column: Int32) -> Int64? {
        sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : sqlite3_column_int64(handle, column)
    }

    public func double(_ column: Int32) -> Double? {
        sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : sqlite3_column_double(handle, column)
    }

    public func data(_ column: Int32) -> Data? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL else { return nil }
        let n = Int(sqlite3_column_bytes(handle, column))
        guard n > 0, let p = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: p, count: n)
    }
}

/// Minimal SQLite wrapper. One connection, used from a single isolation domain.
public final class SQLiteDatabase {
    let handle: OpaquePointer
    private var statements: [String: SQLiteStatement] = [:]
    private var transactionDepth = 0

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if let db { sqlite3_close(db) }
            throw SQLiteError(code: rc, message: message, sql: nil)
        }
        handle = db
        sqlite3_busy_timeout(db, 3000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
    }

    deinit {
        statements.removeAll()
        sqlite3_close_v2(handle)
    }

    private func error(_ rc: Int32, _ sql: String?) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }

    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: message, sql: sql)
        }
    }

    func statement(_ sql: String) throws -> SQLiteStatement {
        if let s = statements[sql] { return s }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc, sql) }
        let s = SQLiteStatement(handle: stmt, sql: sql)
        statements[sql] = s
        return s
    }

    public func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let s = try statement(sql)
        s.bind(values)
        let rc = sqlite3_step(s.handle)
        sqlite3_reset(s.handle)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc, sql) }
    }

    public func query<T>(_ sql: String, _ values: [SQLValue] = [], _ map: (SQLiteStatement) throws -> T) throws -> [T] {
        let s = try statement(sql)
        s.bind(values)
        defer { sqlite3_reset(s.handle) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(s.handle)
            if rc == SQLITE_ROW {
                out.append(try map(s))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw error(rc, sql)
            }
        }
        return out
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try execute("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let result = try body()
            transactionDepth = 0
            try execute("COMMIT")
            return result
        } catch {
            transactionDepth = 0
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int {
        get { (try? query("PRAGMA user_version") { Int($0.int(0) ?? 0) }.first) ?? 0 }
    }

    public func setUserVersion(_ v: Int) throws { try execute("PRAGMA user_version = \(v)") }
}

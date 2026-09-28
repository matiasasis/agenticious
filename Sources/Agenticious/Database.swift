import Foundation
import SQLite3

/// A small wrapper over the SQLite library that ships with macOS. Values bind by position (`?`), rows read by column name.
final class Database {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Row {
        fileprivate let values: [String: Any]

        func string(_ column: String) -> String? { values[column] as? String }
        func int(_ column: String) -> Int? { (values[column] as? Int64).map(Int.init) }
        func double(_ column: String) -> Double? { values[column] as? Double ?? (values[column] as? Int64).map(Double.init) }
        func bool(_ column: String) -> Bool { int(column).map { $0 != 0 } ?? false }
    }

    private var handle: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            defer { sqlite3_close(handle) }
            throw Failure(message: String(cString: sqlite3_errmsg(handle)))
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Bumped by each migration, so every one runs exactly once.
    var schemaVersion: Int {
        get { (try? query("PRAGMA user_version").first?.int("user_version")) ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    func execute(_ sql: String, _ values: Any?...) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure() }
    }

    func query(_ sql: String, _ values: Any?...) throws -> [Row] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(row(from: statement))
            case SQLITE_DONE: return rows
            default: throw failure()
            }
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Statements

    /// SQLite copies bound text instead of keeping a pointer to Swift's temporary buffer.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ values: [Any?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case nil: sqlite3_bind_null(statement, index)
            case let text as String: sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case let flag as Bool: sqlite3_bind_int64(statement, index, flag ? 1 : 0)
            case let number as Int: sqlite3_bind_int64(statement, index, Int64(number))
            case let number as Int32: sqlite3_bind_int64(statement, index, Int64(number))
            case let number as Double: sqlite3_bind_double(statement, index, number)
            default:
                sqlite3_finalize(statement)
                throw Failure(message: "Can't store a \(type(of: value!)) in SQLite")
            }
        }
        return statement
    }

    private func row(from statement: OpaquePointer?) -> Row {
        var values: [String: Any] = [:]
        for column in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, column))
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER: values[name] = sqlite3_column_int64(statement, column)
            case SQLITE_FLOAT: values[name] = sqlite3_column_double(statement, column)
            case SQLITE_TEXT: values[name] = String(cString: sqlite3_column_text(statement, column))
            default: break
            }
        }
        return Row(values: values)
    }

    private func failure() -> Failure {
        Failure(message: String(cString: sqlite3_errmsg(handle)))
    }
}

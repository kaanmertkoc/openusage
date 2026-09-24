import Foundation
@testable import OpenUsage

func openCodeAuthStore(
    files: TextFileAccessing = FakeFiles(),
    sqlite: SQLiteAccessing = OpenCodeFakeSQLite()
) -> OpenCodeAuthStore {
    OpenCodeAuthStore(
        files: files,
        environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
        homeDirectory: { URL(fileURLWithPath: "/nonexistent") },
        sqlite: sqlite
    )
}

/// Stub that returns crafted payloads per database path and classifies the query by SQL shape.
/// Shared by the OpenCode scanner and provider tests. `tables` holds each database's
/// `group_concat(name)` probe output (default: both message tables present). `credentials` holds
/// each OpenCode 2 database's current `openai` row; a database without an entry is OpenCode 1 (no
/// `credential` table), and `""` is a table with no `openai` row.
final class OpenCodeFakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var failing: Set<String>
    var credentials: [String: String]
    var tables: [String: String]
    var credentialTimes: [String: String]
    var lastDataSQL: String?
    var dataSQL: [String: String] = [:]

    init(
        data: [String: String] = [:],
        failing: Set<String> = [],
        credentials: [String: String] = [:],
        tables: [String: String] = [:],
        credentialTimes: [String: String] = [:]
    ) {
        self.data = data
        self.failing = failing
        self.credentials = credentials
        self.tables = tables
        self.credentialTimes = credentialTimes
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        if sql == OpenCodeOpenAIUsageScanner.messageTablesSQL {
            return tables[path] ?? "message,session_message"
        }
        if sql == OpenCodeAuthStore.credentialSQLCurrentOpenAI {
            guard let raw = credentials[path] else {
                throw SQLiteError.queryFailed("Parse error: no such table: credential")
            }
            // Production SQL returns `[value, time_created]`; tests pass just the credential object.
            return raw.isEmpty ? nil : "[\(raw),\(credentialTimes[path] ?? "0")]"
        }
        if sql.contains("json_group_array") {
            lastDataSQL = sql
            dataSQL[path] = sql
            return data[path]
        }
        if sql.contains("SELECT 1") {
            let payload = data[path]
            return (payload != nil && payload != "[]" && !(payload ?? "").isEmpty) ? "1" : nil
        }
        return nil
    }

    func execute(path: String, sql: String) throws {}
}

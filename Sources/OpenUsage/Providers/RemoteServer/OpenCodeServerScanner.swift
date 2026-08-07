import Foundation

enum OpenCodeServerUsageError: Error, LocalizedError {
    /// The synced database exists but couldn't be read. Failing loudly beats rendering an
    /// authoritative-looking idle card from a broken read.
    case databaseUnreadable

    var errorDescription: String? {
        "Couldn't read the synced opencode.db from \(RemoteServerSync.hostLabel). Check ~/.openusage-remote and scripts/remote-sync.sh."
    }
}

/// Reads the rsynced copy of the server's `opencode.db` and aggregates assistant-message tokens per
/// local calendar day. Unlike the local `OpenCodeUsageScanner`, there is no providerID filter — the
/// server runs subscription providers (e.g. `openai`) whose rows cost $0 — and no dollar math at
/// all: the series carries tokens only, so the tiles read "N tokens" instead of a misleading "$0.00".
struct OpenCodeServerScanner: Sendable {
    var sqlite: SQLiteAccessing
    var databasePath: @Sendable () -> String

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePath: @escaping @Sendable () -> String = {
            RemoteServerSync.defaultRoot().appendingPathComponent("opencode/opencode.db").path
        }
    ) {
        self.sqlite = sqlite
        self.databasePath = databasePath
    }

    /// Token totals per day over the last 31 days. `nil` when the synced database doesn't exist yet
    /// (the tiles then render "No data"); throws `databaseUnreadable` when it exists but can't be read.
    func scan(now: Date) throws -> DailyUsageSeries? {
        let path = databasePath()
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let cutoffMs = Int((now.timeIntervalSince1970 - 31 * 86_400) * 1000)
        let json: String?
        do {
            json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs))
        } catch {
            AppLog.warn(LogTag.plugin("opencode-server1"), "usage query failed: \(error.localizedDescription)")
            throw OpenCodeServerUsageError.databaseUnreadable
        }

        var tokensByDay: [String: Int] = [:]
        for row in Self.parseRows(json ?? "[]") {
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            tokensByDay[DailyUsageAccumulator.dayKey(from: date), default: 0] += row.tokens
        }
        let daily = tokensByDay.keys.sorted(by: >).map { day in
            DailyUsageEntry(date: day, totalTokens: tokensByDay[day] ?? 0, costUSD: nil)
        }
        return DailyUsageSeries(daily: daily)
    }

    // MARK: - Parsing

    private struct Row {
        var ms: Double
        var tokens: Int
    }

    /// Parse the `json_group_array(json_array(...))` payload: an array of `[time_created, tokens]`.
    /// Rows with a missing timestamp are skipped at this boundary.
    private static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }

        var rows: [Row] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 2,
                  let ms = ProviderParse.number(entry[0])
            else { continue }
            // Clamp before the Int conversion so a corrupt token count can't trap (Int(Double) crashes
            // above Int.max). 1e15 is far above any real token total.
            let tokens = Int(min(max(ProviderParse.number(entry[1]) ?? 0, 0), 1e15))
            rows.append(Row(ms: ms, tokens: tokens))
        }
        return rows
    }

    // MARK: - SQL

    static func dataSQL(cutoffMs: Int) -> String {
        """
        SELECT json_group_array(json_array(
                 time_created,
                 COALESCE(json_extract(data,'$.tokens.total'),0)))
        FROM message
        WHERE time_created >= \(cutoffMs)
          AND json_valid(data)
          AND json_extract(data,'$.role') = 'assistant';
        """
    }
}

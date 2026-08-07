import XCTest
@testable import OpenUsage

final class OpenCodeServerScannerTests: XCTestCase {
    private var dbFile: URL!

    override func setUpWithError() throws {
        // The scanner checks file existence before querying, so the fake db must exist on disk.
        dbFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-server-tests-\(UUID().uuidString).db")
        try "stub".write(to: dbFile, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dbFile)
    }

    private func scanner(payload: String? = nil, failing: Bool = false) -> OpenCodeServerScanner {
        OpenCodeServerScanner(
            sqlite: FakeSQLite(payload: payload, failing: failing),
            databasePath: { [path = dbFile.path] in path }
        )
    }

    func testMissingDatabaseScansAsNil() throws {
        let missing = OpenCodeServerScanner(
            sqlite: FakeSQLite(payload: nil),
            databasePath: { "/nonexistent/opencode.db" }
        )
        XCTAssertNil(try missing.scan(now: Date()))
    }

    func testAggregatesTokensPerLocalDayWithoutDollars() throws {
        let now = Date(timeIntervalSince1970: 1_754_600_000)
        let todayMs = Int(now.timeIntervalSince1970 * 1000) - 3_600_000
        let yesterdayMs = Int(now.timeIntervalSince1970 * 1000) - 26 * 3_600_000
        let payload = "[[\(todayMs),1000],[\(todayMs - 1000),500],[\(yesterdayMs),3000]]"

        let series = try XCTUnwrap(scanner(payload: payload).scan(now: now))

        let todayKey = DailyUsageAccumulator.dayKey(from: Date(timeIntervalSince1970: Double(todayMs) / 1000))
        let yesterdayKey = DailyUsageAccumulator.dayKey(from: Date(timeIntervalSince1970: Double(yesterdayMs) / 1000))
        let byDay = Dictionary(uniqueKeysWithValues: series.daily.map { ($0.date, $0) })
        XCTAssertEqual(byDay[todayKey]?.totalTokens, 1500)
        XCTAssertEqual(byDay[yesterdayKey]?.totalTokens, 3000)
        // Server usage is subscription-billed: no dollars, ever — a nil cost keeps the tiles token-only.
        XCTAssertTrue(series.daily.allSatisfy { $0.costUSD == nil })
    }

    func testQueryHasNoProviderFilter() throws {
        // The server runs arbitrary providers (openai, opencode, ...); all assistant rows count.
        let sql = OpenCodeServerScanner.dataSQL(cutoffMs: 0)
        XCTAssertFalse(sql.contains("providerID"))
        XCTAssertTrue(sql.contains("'$.role') = 'assistant'"))
        XCTAssertTrue(sql.contains("$.tokens.total"))
    }

    func testMalformedRowsAreSkipped() throws {
        let now = Date(timeIntervalSince1970: 1_754_600_000)
        let ms = Int(now.timeIntervalSince1970 * 1000) - 1000
        let payload = "[[null,1000],[\(ms),200],\"junk\"]"

        let series = try XCTUnwrap(scanner(payload: payload).scan(now: now))
        XCTAssertEqual(series.daily.reduce(0) { $0 + $1.totalTokens }, 200)
    }

    func testUnreadableDatabaseThrows() {
        XCTAssertThrowsError(try scanner(failing: true).scan(now: Date())) { error in
            XCTAssertEqual(error as? OpenCodeServerUsageError, .databaseUnreadable)
        }
    }
}

final class RemoteServerLayoutTests: XCTestCase {
    func testDefaultLayoutSeedsTheServerTiles() {
        for id in [
            "claude-server1.today", "claude-server1.yesterday", "claude-server1.last30", "claude-server1.trend",
            "opencode-server1.today", "opencode-server1.yesterday", "opencode-server1.last30", "opencode-server1.trend"
        ] {
            XCTAssertTrue(DefaultLayout.metricIDs.contains(id), "\(id) missing from DefaultLayout.metricIDs")
        }
        // Today stays above the fold; everything else sits below the caret.
        for id in [
            "claude-server1.yesterday", "claude-server1.last30", "claude-server1.trend",
            "opencode-server1.yesterday", "opencode-server1.last30", "opencode-server1.trend"
        ] {
            XCTAssertTrue(DefaultLayout.expandedMetricIDs.contains(id), "\(id) missing from expandedMetricIDs")
        }
        XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains("claude-server1.today"))
        XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains("opencode-server1.today"))
    }

    @MainActor
    func testCatalogRegistersTheServerProviders() {
        let ids = ProviderCatalog.make().map(\.provider.id)
        XCTAssertTrue(ids.contains("claude-server1"))
        XCTAssertTrue(ids.contains("opencode-server1"))
        // Right after their local counterparts.
        XCTAssertEqual(ids.firstIndex(of: "claude-server1"), ids.firstIndex(of: "claude-work").map { $0 + 1 })
        XCTAssertEqual(ids.firstIndex(of: "opencode-server1"), ids.firstIndex(of: "opencode").map { $0 + 1 })
    }
}

/// Minimal SQLite stub: one payload for the data query, optional hard failure.
private final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
    let payload: String?
    let failing: Bool

    init(payload: String?, failing: Bool = false) {
        self.payload = payload
        self.failing = failing
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing { throw SQLiteError.queryFailed("boom") }
        return payload
    }

    func execute(path: String, sql: String) throws {}
}

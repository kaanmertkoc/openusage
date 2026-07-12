import XCTest
@testable import OpenUsage

/// The SQLite scanner: unions `opencode*.db` files, sums combined hosted spend for the tiles/trend, and
/// derives Go-only windows for the meters. Fed a stub `SQLiteAccessing` that returns crafted
/// `json_group_array` payloads keyed by path.
final class OpenCodeUsageScannerTests: XCTestCase {
    private func d(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Int { Int(d(iso).timeIntervalSince1970 * 1000) }
    private func row(_ iso: String, _ cost: String, _ tokens: Int, _ model: String, _ provider: String) -> String {
        "[\(epochMs(iso)),\(cost),\(tokens),\"\(model)\",\"\(provider)\"]"
    }
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private var db1: String {
        "[" + [
            row("2026-07-12T11:00:00.000Z", "2.0", 1000, "glm-5.2", "opencode-go"),  // today, go, in session
            row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode"),      // today, zen
            row("2026-07-11T10:00:00.000Z", "3.0", 2000, "kimi-k2.6", "opencode-go"),// yesterday, go
            row("2026-07-12T11:00:00.000Z", "null", 100, "x", "opencode-go"),        // null cost → skipped
            "\"garbage\""                                                             // non-array → skipped
        ].joined(separator: ",") + "]"
    }
    private var db2: String {
        "[" + row("2026-07-12T09:00:00.000Z", "4.0", 800, "deepseek-v4-pro", "opencode-go") + "]"
    }

    private func standardScanner() -> OpenCodeUsageScanner {
        let sqlite = FakeSQLite(data: [
            "/oc/opencode.db": db1,
            "/oc/opencode-next.db": db2
        ])
        return OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] })
    }

    func testCombinedHostedSeriesUnionsDatabasesAndSkipsGarbage() async {
        guard let scan = await standardScanner().scan(now: now) else { return XCTFail("expected a scan") }
        let totalCost = scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +)
        let totalTokens = scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }
        // opencode-go 2+3+4 plus Zen 1 = 10; the null-cost and "garbage" rows are dropped.
        XCTAssertEqual(totalCost, 10.0, accuracy: 0.0001)
        XCTAssertEqual(totalTokens, 4300) // 1000 + 500 + 2000 + 800
    }

    func testSessionSumsOnlyGoAcrossDatabases() async {
        guard let scan = await standardScanner().scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertNotNil(scan.goWindows)
        // Session window (last 5h) contains the two go rows (11:00 = 2.0, 09:00 = 4.0); the Zen row at
        // 10:00 is excluded from the Go cap even though it counts toward combined spend.
        XCTAssertEqual(scan.goWindows?.sessionSpend ?? -1, 6.0, accuracy: 0.0001)
    }

    func testZenOnlyUsageHasNoGoWindows() async {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertNil(scan.goWindows) // no Go footprint → no empty cap meters
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 1.0, accuracy: 0.0001)
    }

    func testMissingDatabaseReturnsNil() async {
        let scanner = OpenCodeUsageScanner(sqlite: FakeSQLite(), databasePaths: { [] })
        let scan = await scanner.scan(now: now)
        XCTAssertNil(scan)
    }

    func testEmptyDatabaseYieldsEmptyScanNotNil() async {
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": "[]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertTrue(scan.logScan.series.daily.isEmpty)
        XCTAssertNil(scan.goWindows)
    }

    func testFailingDatabaseIsSkippedNotFatal() async {
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode-next.db": db2], failing: ["/oc/opencode.db"]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        guard let scan = await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 4.0, accuracy: 0.0001)
    }

    func testHasHostedUsageProbe() {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let withUsage = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        XCTAssertTrue(withUsage.hasHostedUsage())

        let empty = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": "[]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        XCTAssertFalse(empty.hasHostedUsage())
    }

    func testAbsurdTokenCountIsClampedNotCrashing() async {
        // A corrupt token count over Int.max must clamp (to 1e15), not trap the Int(Double) conversion.
        let db = "[[\(epochMs("2026-07-12T10:00:00.000Z")),1.0,1e19,\"glm-5.2\",\"opencode-go\"]]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        let tokens = scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(tokens, 1_000_000_000_000_000)
    }

    func testStaleGoAnchorWithoutRecentSpendOrKeyHasNoGoWindows() async {
        // Old opencode-go usage left an anchor, but there's no recent Go spend and no auth key: the caps
        // (and the "Go" badge) must NOT come back for a lapsed/Zen-only user.
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db], anchors: ["/oc/opencode.db": "1700000000000"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = await scanner.scan(now: now, hasGoKey: false) else { return XCTFail("expected a scan") }
        XCTAssertNil(scan.goWindows)
    }

    func testGoKeyShowsWindowsEvenWithoutRecentSpend() async {
        // Logged into Go but idle in-window → still show the caps at $0, using the anchor for the month.
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db], anchors: ["/oc/opencode.db": "1700000000000"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = await scanner.scan(now: now, hasGoKey: true) else { return XCTFail("expected a scan") }
        XCTAssertNotNil(scan.goWindows)
        XCTAssertEqual(scan.goWindows?.sessionSpend ?? -1, 0, accuracy: 0.0001)
    }
}

/// Stub that returns crafted payloads per database path and classifies the query by SQL shape.
private final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var anchors: [String: String]
    var failing: Set<String>

    init(data: [String: String] = [:], anchors: [String: String] = [:], failing: Set<String> = []) {
        self.data = data
        self.anchors = anchors
        self.failing = failing
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        if sql.contains("json_group_array") { return data[path] }
        if sql.contains("MIN(time_created)") { return anchors[path] }
        if sql.contains("SELECT 1") {
            let payload = data[path]
            return (payload != nil && payload != "[]" && !(payload ?? "").isEmpty) ? "1" : nil
        }
        return nil
    }

    func execute(path: String, sql: String) throws {}
}

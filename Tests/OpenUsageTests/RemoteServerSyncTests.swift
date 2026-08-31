import XCTest
@testable import OpenUsage

final class RemoteServerSyncTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-sync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func writeMarker(_ contents: String, leg: RemoteServerSync.Leg = .claude) throws {
        let dir = root.appendingPathComponent(leg.rawValue)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try contents.write(to: dir.appendingPathComponent(".last-sync"), atomically: true, encoding: .utf8)
    }

    func testMissingMarkerReadsAsNeverSynced() {
        XCTAssertNil(RemoteServerSync.lastSyncDate(root: root, leg: .claude))
    }

    func testParsesTheSyncScriptTimestampFormat() throws {
        // scripts/remote-sync.sh writes `date -u +"%Y-%m-%dT%H:%M:%SZ"` plus a trailing newline.
        try writeMarker("2026-08-07T12:56:54Z\n")
        let parsed = RemoteServerSync.lastSyncDate(root: root, leg: .claude)
        XCTAssertEqual(parsed, OpenUsageISO8601.date(from: "2026-08-07T12:56:54Z"))
    }

    func testGarbageMarkerReadsAsNeverSynced() throws {
        try writeMarker("not a timestamp")
        XCTAssertNil(RemoteServerSync.lastSyncDate(root: root, leg: .claude))
    }

    /// Regression: the sync legs each carry their own marker. They used to share one
    /// host-level `.last-sync`, so a failing opencode rsync (the 2.5 GB database timing out) made the
    /// Claude tile claim staleness even though its own leg had just synced.
    func testLegMarkersAreReadIndependently() throws {
        try writeMarker("2026-08-07T12:56:54Z\n", leg: .claude)
        try writeMarker("2026-08-07T11:30:00Z\n", leg: .codex)
        try writeMarker("2026-08-07T09:00:00Z\n", leg: .opencode)
        XCTAssertEqual(
            RemoteServerSync.lastSyncDate(root: root, leg: .claude),
            OpenUsageISO8601.date(from: "2026-08-07T12:56:54Z")
        )
        XCTAssertEqual(
            RemoteServerSync.lastSyncDate(root: root, leg: .codex),
            OpenUsageISO8601.date(from: "2026-08-07T11:30:00Z")
        )
        XCTAssertEqual(
            RemoteServerSync.lastSyncDate(root: root, leg: .opencode),
            OpenUsageISO8601.date(from: "2026-08-07T09:00:00Z")
        )
    }

    func testOneLegSyncedLeavesTheOtherNeverSynced() throws {
        try writeMarker("2026-08-07T12:56:54Z\n", leg: .claude)
        XCTAssertNil(RemoteServerSync.lastSyncDate(root: root, leg: .codex))
        XCTAssertNil(RemoteServerSync.lastSyncDate(root: root, leg: .opencode))
    }

    func testFreshSyncCarriesNoWarning() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(RemoteServerSync.staleWarning(lastSync: now.addingTimeInterval(-5 * 60), now: now))
    }

    func testStaleSyncWarnsWithMinuteAge() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let warning = try XCTUnwrap(
            RemoteServerSync.staleWarning(lastSync: now.addingTimeInterval(-60 * 60), now: now)
        )
        XCTAssertTrue(warning.contains("60m"), "unexpected warning: \(warning)")
    }

    func testVeryStaleSyncWarnsInHours() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let warning = try XCTUnwrap(
            RemoteServerSync.staleWarning(lastSync: now.addingTimeInterval(-5 * 3600), now: now)
        )
        XCTAssertTrue(warning.contains("5h"), "unexpected warning: \(warning)")
    }

    // MARK: - Per-tile staleness

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Regression for the reported bug: the opencode leg had been failing for hours (the 2.5 GB
    /// database sync timing out) while the Claude leg synced fine every 5 minutes, yet the Claude
    /// Server tile still showed the amber "sync is stale" triangle.
    @MainActor
    func testClaudeTileIgnoresAStaleOpenCodeLeg() async throws {
        try writeMarker(Self.iso(Self.now.addingTimeInterval(-2 * 60)), leg: .claude)
        try writeMarker(Self.iso(Self.now.addingTimeInterval(-5 * 3600)), leg: .opencode)
        let snapshot = await ClaudeServerProvider(
            syncRoot: root,
            now: { Self.now },
            pricing: { .empty }
        ).refresh()
        XCTAssertNil(snapshot.warning)
    }

    @MainActor
    func testClaudeTileWarnsOnItsOwnStaleLeg() async throws {
        try writeMarker(Self.iso(Self.now.addingTimeInterval(-5 * 3600)), leg: .claude)
        let snapshot = await ClaudeServerProvider(
            syncRoot: root,
            now: { Self.now },
            pricing: { .empty }
        ).refresh()
        XCTAssertNotNil(snapshot.warning)
    }

    @MainActor
    func testOpenCodeTileIgnoresAStaleClaudeLeg() async throws {
        try writeMarker(Self.iso(Self.now.addingTimeInterval(-5 * 3600)), leg: .claude)
        try writeMarker(Self.iso(Self.now.addingTimeInterval(-2 * 60)), leg: .opencode)
        let snapshot = await OpenCodeServerProvider(
            syncRoot: root,
            scanner: OpenCodeServerScanner(databasePath: { "/nonexistent/openusage-tests/opencode.db" }),
            now: { Self.now }
        ).refresh()
        XCTAssertNil(snapshot.warning)
    }

    @MainActor
    func testCodexTileReadsOnlyItsSyncedRollouts() async throws {
        try writeMarker(Self.iso(Self.now.addingTimeInterval(-2 * 60)), leg: .codex)
        let sessions = root.appendingPathComponent("codex/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let timestamp = OpenUsageISO8601.string(from: Self.now.addingTimeInterval(-60))
        let rollout = [
            CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-5.3-codex"),
            CodexLogFixture.tokenCount(
                timestamp: timestamp,
                last: CodexLogFixture.usage(input: 1_000, cached: 200, output: 100)
            )
        ].joined(separator: "\n")
        try rollout.write(
            to: sessions.appendingPathComponent("server-rollout.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = await CodexServerProvider(
            syncRoot: root,
            now: { Self.now },
            pricing: { TestPricing.bundled }
        ).refresh()

        XCTAssertEqual(snapshot.providerID, "codex-server1")
        XCTAssertNil(snapshot.warning)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.line(label: "Last 30 Days"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.line(label: "Weekly"))
    }

    @MainActor
    func testCodexTileIgnoresAStaleClaudeLeg() async throws {
        try writeMarker(Self.iso(Self.now.addingTimeInterval(-5 * 3600)), leg: .claude)
        try writeMarker(Self.iso(Self.now.addingTimeInterval(-2 * 60)), leg: .codex)
        let snapshot = await CodexServerProvider(
            syncRoot: root,
            now: { Self.now },
            pricing: { .empty }
        ).refresh()
        XCTAssertNil(snapshot.warning)
    }

    private static func iso(_ date: Date) -> String {
        OpenUsageISO8601.string(from: date) + "\n"
    }
}

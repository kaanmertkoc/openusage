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

    private func writeMarker(_ contents: String) throws {
        try contents.write(to: root.appendingPathComponent(".last-sync"), atomically: true, encoding: .utf8)
    }

    func testMissingMarkerReadsAsNeverSynced() {
        XCTAssertNil(RemoteServerSync.lastSyncDate(root: root))
    }

    func testParsesTheSyncScriptTimestampFormat() throws {
        // scripts/remote-sync.sh writes `date -u +"%Y-%m-%dT%H:%M:%SZ"` plus a trailing newline.
        try writeMarker("2026-08-07T12:56:54Z\n")
        let parsed = RemoteServerSync.lastSyncDate(root: root)
        XCTAssertEqual(parsed, OpenUsageISO8601.date(from: "2026-08-07T12:56:54Z"))
    }

    func testGarbageMarkerReadsAsNeverSynced() throws {
        try writeMarker("not a timestamp")
        XCTAssertNil(RemoteServerSync.lastSyncDate(root: root))
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
}

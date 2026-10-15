import XCTest
@testable import OpenUsage

@MainActor
final class RemoteClaudeServerTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testServersKeepUsageAndFreshnessSeparateAcrossRefreshes() async throws {
        let first = server("first", name: "First Server")
        let second = server("second", name: "Second Server")
        try writeUsage(first, tokens: 110)
        try writeUsage(second, tokens: 240)
        try marker(first, at: now)
        try marker(second, at: now.addingTimeInterval(-3600))
        let a = provider(first)
        let b = provider(second)
        let initialA = await a.refresh()
        let initialB = await b.refresh()
        XCTAssertEqual(try tokens(initialA), 110)
        XCTAssertEqual(try tokens(initialB), 240)
        XCTAssertNil(initialA.warning)
        XCTAssertNotNil(initialB.warning)
        XCTAssertEqual(initialA.providerID, "claude-first")
        XCTAssertEqual(initialB.displayName, "Claude · Second Server")
        XCTAssertNil(initialA.line(label: "Session"))
        XCTAssertNil(initialA.line(label: "Weekly"))
        try writeUsage(first, tokens: 330)
        let changedA = await a.refresh()
        let unchangedB = await b.refresh()
        XCTAssertEqual(try tokens(changedA), 330)
        XCTAssertEqual(try tokens(unchangedB), 240)
    }

    func testOfflinePauseRetainsNumbersThenClearsAfterReconnect() async throws {
        let host = server("first", name: "First Server")
        try writeUsage(host, tokens: 110)
        try marker(host, at: now)
        let runtime = provider(host)
        let paused = root.appendingPathComponent(".sync-paused")
        try "Sync Paused — Tailscale Offline".write(to: paused, atomically: true, encoding: .utf8)
        let offline = await runtime.refresh()
        XCTAssertEqual(try tokens(offline), 110)
        XCTAssertEqual(offline.warning, "Sync Paused — Tailscale Offline")
        try "".write(to: paused, atomically: true, encoding: .utf8)
        let online = await runtime.refresh()
        XCTAssertNil(online.warning)
        XCTAssertEqual(try tokens(online), 110)
    }

    func testNeverSyncedServerReportsItsOwnFailureAndCanBeEnabled() async throws {
        let host = server("second", name: "Second Server")
        let directory = root.appendingPathComponent("second/claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "Could not sync Claude from Second Server".write(
            to: directory.appendingPathComponent(".sync-error"), atomically: true, encoding: .utf8
        )
        let runtime = provider(host)
        let detected = await runtime.hasLocalCredentials()
        XCTAssertTrue(detected)
        let result = await runtime.refresh()
        XCTAssertTrue(result.lines.contains(where: \.isError))
        XCTAssertNil(result.line(label: "Today"))
        guard case .badge(_, let message, _, _) = result.lines.first else { return XCTFail("Missing error") }
        XCTAssertTrue(message.contains("Second Server"))
    }

    func testConfiguredCardsPreserveLegacyIDAndMetricDefaults() {
        let servers = RemoteClaudeServer.configured
        XCTAssertTrue(servers.contains { $0.id == "server1" })
        XCTAssertTrue(servers.contains { $0.id == "mac-mini" })
        XCTAssertEqual(Set(servers.map(\.providerID)).count, servers.count)
        for server in servers {
            let runtime = ClaudeServerProvider(server: server)
            XCTAssertEqual(runtime.widgetDescriptors.map(\.id),
                           ["trend", "today", "yesterday", "last30"].map { "\(server.providerID).\($0)" })
            for metric in ["today", "yesterday", "last30", "trend"] {
                let id = "\(server.providerID).\(metric)"
                XCTAssertTrue(DefaultLayout.metricIDs.contains(id))
                XCTAssertEqual(DefaultLayout.expandedMetricIDs.contains(id), metric != "today")
                XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains(id))
            }
        }
    }

    func testPendingServerAppearsBeforeFirstSyncWithoutInventingUsage() async {
        let host = RemoteClaudeServer(id: "pending", name: "Pending Mac", setupRequired: "SSH Setup Required")
        let runtime = provider(host)
        let detected = await runtime.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await runtime.refresh()
        XCTAssertNil(snapshot.line(label: "Today"))
        guard case .badge(_, let message, _, _) = snapshot.lines.first else { return XCTFail("Missing setup error") }
        XCTAssertEqual(message, "SSH Setup Required")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("pending").path))
    }

    func testPendingConfigurationRequiresExplicitReasonAndNoConnectionDetails() throws {
        let ready: [String: Any] = ["id": "server1", "name": "Server", "sshTarget": "root@100.1.1.1",
                                    "claudeProjectsPath": "/root/.claude/projects"]
        var pending: [String: Any] = ["id": "pending", "name": "Pending Mac", "setupRequired": "SSH Setup Required"]
        XCTAssertEqual(try RemoteClaudeServer.decode(JSONSerialization.data(withJSONObject: [ready, pending])).count, 2)
        pending["sshTarget"] = "guessed@100.1.1.2"
        XCTAssertThrowsError(try RemoteClaudeServer.decode(JSONSerialization.data(withJSONObject: [ready, pending])))
        pending.removeValue(forKey: "sshTarget")
        pending["setupRequired"] = " "
        XCTAssertThrowsError(try RemoteClaudeServer.decode(JSONSerialization.data(withJSONObject: [ready, pending])))
        pending.removeValue(forKey: "setupRequired")
        XCTAssertThrowsError(try RemoteClaudeServer.decode(JSONSerialization.data(withJSONObject: [ready, pending])))
    }

    func testNewServerDefaultsDoNotOverwriteExistingCustomization() {
        let suite = "RemoteClaudeServerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude-server1.today")])
        persistence.saveSeededDefaults(Set(["today", "yesterday", "last30", "trend"].map { "claude-server1.\($0)" }))
        persistence.saveExpandedMetrics([])
        persistence.savePins(["claude-server1.today"])
        let runtimes: [ProviderRuntime] = RemoteClaudeServer.configured.map { ClaudeServerProvider(server: $0) }
        let state = LayoutBootstrap.load(
            registry: WidgetRegistry.from(runtimes), persistence: persistence,
            defaults: LayoutDefaultSet(
                metricIDs: DefaultLayout.metricIDs, migrationBaselineMetricIDs: DefaultLayout.migrationBaselineMetricIDs,
                pinnedMetricIDs: DefaultLayout.pinnedMetricIDs, expandedMetricIDs: DefaultLayout.expandedMetricIDs
            )
        )
        XCTAssertFalse(state.placed.contains { $0.descriptorID == "claude-server1.yesterday" })
        XCTAssertEqual(state.pinnedMetricIDs, ["claude-server1.today"])
        for host in RemoteClaudeServer.configured where host.id != "server1" {
            XCTAssertTrue(state.placed.contains { $0.descriptorID == "\(host.providerID).today" })
            XCTAssertTrue(state.expandedMetricIDs.contains("\(host.providerID).yesterday"))
            XCTAssertFalse(state.expandedMetricIDs.contains("\(host.providerID).today"))
        }
    }

    func testConfigurationRejectsDuplicateAndUnsafeIDs() throws {
        let url = Bundle.openUsageResources.url(forResource: "remote_servers", withExtension: "json")!
        let data = try Data(contentsOf: url)
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        entries.append(entries[0])
        XCTAssertThrowsError(try RemoteClaudeServer.decode(JSONSerialization.data(withJSONObject: entries)))
        entries.removeLast()
        entries[0]["id"] = "../wrong-server"
        XCTAssertThrowsError(try RemoteClaudeServer.decode(JSONSerialization.data(withJSONObject: entries)))
    }

    private func server(_ id: String, name: String) -> RemoteClaudeServer {
        RemoteClaudeServer(id: id, name: name, sshTarget: "root@100.1.1.1", claudeProjectsPath: "/root/.claude/projects")
    }

    private func provider(_ server: RemoteClaudeServer) -> ClaudeServerProvider {
        let date = now
        return ClaudeServerProvider(server: server, syncRoot: root.appendingPathComponent(server.id),
                                    now: { date }, pricing: { .empty })
    }

    private func writeUsage(_ server: RemoteClaudeServer, tokens: Int) throws {
        let directory = root.appendingPathComponent("\(server.id)/claude/projects/workspace/session/subagents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = ClaudeLogFixture.usageLine(timestamp: OpenUsageISO8601.string(from: now), input: tokens,
                                            output: 0, costUSD: 1, messageID: "same-id", requestID: "same-request")
        // Replayed log entries count once inside a server, while scanners keep machines independent.
        try (line + "\n" + line).write(to: directory.appendingPathComponent("agent.jsonl"), atomically: true, encoding: .utf8)
    }

    private func marker(_ server: RemoteClaudeServer, at date: Date) throws {
        try OpenUsageISO8601.string(from: date).write(
            to: root.appendingPathComponent("\(server.id)/claude/.last-sync"), atomically: true, encoding: .utf8
        )
    }

    private func tokens(_ snapshot: ProviderSnapshot) throws -> Double {
        guard case .values(_, let values, _, _, _, _) = snapshot.line(label: "Today") else {
            throw NSError(domain: "Missing Today", code: 1)
        }
        return try XCTUnwrap(values.first { $0.kind == .count }?.number)
    }
}

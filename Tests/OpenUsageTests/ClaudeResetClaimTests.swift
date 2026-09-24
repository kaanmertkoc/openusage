import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeResetClaimTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let organization = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    private final class Server: @unchecked Sendable {
        var account = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        var grantOverrides: [String: Any] = [:]
        var statusOverrides: [String: Any] = [:]
        var result = "reset"
        var reason: String?
        var failPost = false
        func response(_ request: HTTPRequest) throws -> HTTPResponse {
            let body: [String: Any]
            if request.method == "POST" {
                if failPost { throw URLError(.timedOut) }
                var resultBody = ["result": result]
                if let reason { resultBody["reason"] = reason }
                body = resultBody
            } else if request.url.path.hasSuffix("profile") {
                body = ["account": ["uuid": account], "organization": ["uuid": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]]
            } else {
                var grant: [String: Any] = ["id": "grant_one", "label": "Gift", "resets_left": 2,
                    "ends_at": "2030-01-01T00:00:00Z", "clears": ["five_hour", "seven_day"],
                    "usable_now": true, "use_requires_limit": false, "blocking": []]
                grant.merge(grantOverrides) { _, new in new }
                var status: [String: Any] = ["eligible": true, "next_grant_id": "grant_one", "grants": [grant]]
                status.merge(statusOverrides) { _, new in new }
                body = ["cedar_ember": status]
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: body))
        }
    }

    private func setup(_ server: Server = Server(), defaults: UserDefaults? = nil, providerID: String = "claude") -> (ClaudeResetClaimService, RoutingHTTPClient, UserDefaults) {
        let http = RoutingHTTPClient { try server.response($0) }
        let store = defaults ?? UserDefaults(suiteName: "ClaudeResetTests.\(UUID())")!
        let config = ClaudeOAuthConfig(usageURL: URL(string: "https://example.invalid/api/oauth/usage")!,
            refreshURL: URL(string: "https://example.invalid/token")!, clientID: "test")
        let service = ClaudeResetClaimService(providerID: providerID, displayName: providerID,
            client: ClaudeUsageClient(httpClient: http), defaults: store, now: { self.date },
            credentials: { ClaudeResetCredentials(accessToken: "test-token", config: config) })
        return (service, http, store)
    }

    func testReadsPreparationAndCancellationNeverRedeem() async {
        let (service, http, _) = setup()
        await service.confirm()
        await service.load()
        XCTAssertEqual(service.grants.first?.resetsLeft, 2)
        service.prepare(grantID: "grant_one")
        XCTAssertNotNil(service.confirmation)
        service.cancel()
        await service.confirm()
        XCTAssertTrue(http.requests.allSatisfy { $0.method == "GET" })
        XCTAssertTrue(http.requests.contains { $0.url.query == "cedar_ember=1" })
    }

    func testExplicitConfirmationSendsOneExactRequest() async throws {
        let (service, http, _) = setup()
        await service.load()
        service.prepare(grantID: "grant_one")
        let requestID = try XCTUnwrap(service.confirmation?.requestID)
        async let first: Void = service.confirm()
        async let second: Void = service.confirm()
        _ = await (first, second)
        let posts = http.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 1)
        let post = try XCTUnwrap(posts.first)
        XCTAssertEqual(post.url.absoluteString, "https://example.invalid/api/organizations/\(organization)/reset_rate_limits")
        let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(post.body))
        XCTAssertEqual(body, ["program": "cedar_ember", "grant_id": "grant_one", "request_id": requestID])
        XCTAssertNil(service.unresolved)
        XCTAssertEqual(service.message, "Reset used for claude.")
    }

    func testAccountSwitchBetweenSelectionAndConfirmationStopsWrite() async {
        let server = Server()
        let (service, http, _) = setup(server)
        await service.load()
        service.prepare(grantID: "grant_one")
        server.account = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        await service.confirm()
        XCTAssertFalse(http.requests.contains { $0.method == "POST" })
        XCTAssertTrue(service.message?.contains("account changed") == true)
    }

    func testGrantChangesStopWrite() async {
        let changes: [[String: Any]] = [
            ["paused": true], ["usable_now": false], ["resets_left": 0],
            ["ends_at": "2020-01-01T00:00:00Z"], ["starts_at": "2030-01-01T00:00:00Z"],
            ["clears": ["five_hour"]], ["clears": ["future_limit"]], ["blocking": ["seven_day"]],
            ["use_requires_limit": true]
        ]
        for change in changes {
            let server = Server()
            let (service, http, _) = setup(server)
            await service.load()
            service.prepare(grantID: "grant_one")
            server.grantOverrides = change
            await service.confirm()
            XCTAssertFalse(http.requests.contains { $0.method == "POST" }, "\(change)")
        }
    }

    func testEligibilityCooldownAndNextGrantAreRechecked() async {
        for change: [String: Any] in [["eligible": false], ["next_grant_id": "other"], ["cooldown_until": "2030-01-01T00:00:00Z"]] {
            let server = Server()
            let (service, http, _) = setup(server)
            await service.load()
            service.prepare(grantID: "grant_one")
            server.statusOverrides = change
            await service.confirm()
            XCTAssertFalse(http.requests.contains { $0.method == "POST" })
        }
    }

    func testUncertainRequestSurvivesRestartAndExplicitRetryReusesID() async throws {
        let server = Server()
        server.failPost = true
        let (service, http, defaults) = setup(server)
        await service.load()
        service.prepare(grantID: "grant_one")
        let selected = try XCTUnwrap(service.confirmation)
        await service.confirm()
        XCTAssertEqual(service.unresolved, selected)
        let (restarted, retryHTTP, _) = setup(server, defaults: defaults)
        await restarted.load()
        restarted.prepare(grantID: "grant_one")
        XCTAssertNil(restarted.confirmation)
        XCTAssertFalse(retryHTTP.requests.contains { $0.method == "POST" })
        server.failPost = false
        server.result = "already_used"
        restarted.prepareRetry()
        XCTAssertEqual(restarted.confirmation, selected)
        await restarted.confirm()
        let original = try XCTUnwrap(http.requests.first { $0.method == "POST" }?.body)
        let retry = try XCTUnwrap(retryHTTP.requests.first { $0.method == "POST" }?.body)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: original),
                       try JSONDecoder().decode([String: String].self, from: retry))
        XCTAssertNil(restarted.unresolved)
    }

    func testIndeterminateResultsKeepPendingRequest() async {
        for reason in ["stamp_indeterminate", "reset_unconfirmed"] {
            let server = Server()
            server.reason = reason
            let (service, _, _) = setup(server)
            await service.load()
            service.prepare(grantID: "grant_one")
            await service.confirm()
            XCTAssertNotNil(service.unresolved)
        }
    }

    func testMalformedSavedAttemptFailsClosedAndDoesNotAffectWork() async {
        let defaults = UserDefaults(suiteName: "ClaudeResetTests.\(UUID())")!
        defaults.set(Data("broken".utf8), forKey: "openusage.claudeReset.pending.claude")
        let (service, http, _) = setup(defaults: defaults)
        await service.load()
        service.prepare(grantID: "grant_one")
        service.prepareRetry()
        await service.confirm()
        XCTAssertNil(service.confirmation)
        XCTAssertFalse(http.requests.contains { $0.method == "POST" })
        let (work, _, _) = setup(defaults: defaults, providerID: "claude-work")
        await work.load()
        work.prepare(grantID: "grant_one")
        XCTAssertNotNil(work.confirmation)
    }

    func testRequestedDefaultPlacement() {
        for provider in ["claude", "claude-work"] {
            let id = "\(provider).rateLimitResets"
            XCTAssertTrue(DefaultLayout.metricIDs.contains(id))
            XCTAssertTrue(DefaultLayout.expandedMetricIDs.contains(id))
            XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains(id))
            XCTAssertFalse(DefaultLayout.migrationBaselineMetricIDs.contains(id))
        }
    }
}

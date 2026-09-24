import XCTest
@testable import OpenUsage

final class ClaudePersonalWorkflowTests: XCTestCase {
    func testNestedWorkflowsStayInTheirConfiguredAccountAndRefreshWithoutDuplicates() async throws {
        let now = Date()
        func usage(_ id: String, _ tokens: Int) -> String {
            ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now), input: tokens, output: 0,
                costUSD: 1, messageID: id, requestID: id
            )
        }
        let workflow = "workspace/session/subagents/workflows/wf-1/agent.jsonl"
        let personal = try ClaudeLogFixture.makeHome(files: [
            "workspace/session.jsonl": usage("parent", 10),
            workflow: usage("agent", 100),
            "workspace/session/subagents/workflows/wf-2/replay.jsonl": usage("agent", 100)
        ])
        let work = try ClaudeLogFixture.makeHome(files: [workflow: usage("work", 200)])
        defer {
            try? FileManager.default.removeItem(at: personal)
            try? FileManager.default.removeItem(at: work)
        }
        let cache = IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
        func scanner(_ root: URL) -> ClaudeLogUsageScanner {
            ClaudeLogUsageScanner(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": root.path]),
                homeDirectory: { root }, includeCoworkSandboxes: false, incrementalScanner: cache
            )
        }
        let personalScanner = scanner(personal)
        let workScanner = scanner(work)
        let pricing = ModelPricing(
            supplement: PricingSupplement(), primary: PricingCatalog(entries: [:]),
            secondary: PricingCatalog(entries: [:])
        )
        let initial = await personalScanner.scan(now: now, pricing: pricing)
        let workResult = await workScanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(initial?.series.daily.first?.totalTokens, 110)
        XCTAssertEqual(workResult?.series.daily.first?.totalTokens, 200)

        try (usage("agent", 100) + "\n" + usage("new", 50)).write(
            to: personal.appendingPathComponent("projects/" + workflow), atomically: true, encoding: .utf8
        )
        let refreshed = await personalScanner.scan(now: now, pricing: pricing)
        let workAfterRefresh = await workScanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(refreshed?.series.daily.first?.totalTokens, 160)
        XCTAssertEqual(workAfterRefresh?.series.daily.first?.totalTokens, 200)
    }
}

import XCTest
@testable import OpenUsage

/// `OpenCodeOpenAIUsageScanner` — parsing OpenCode's ChatGPT-plan message rows, pricing through the
/// shared store (reasoning bills as output), the unknown-model rule, and the SQL provider filter.
final class OpenCodeOpenAIUsageScannerTests: XCTestCase {
    private let noon = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!

    private func pricing(_ model: String = "gpt-5.3-codex") -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: [model: ModelRates(
                inputPerMillion: 1000, outputPerMillion: 3000,
                cacheWritePerMillion: 0, cacheReadPerMillion: 100
            )]),
            secondary: PricingCatalog(entries: [:])
        )
    }

    private func row(msAgo: Double = 0, model: String = "gpt-5.3-codex",
                     input: Int = 1_000_000, output: Int = 0, reasoning: Int = 0,
                     cacheRead: Int = 0, cacheWrite: Int = 0) -> [Any] {
        [noon.timeIntervalSince1970 * 1000 - msAgo, model, input, output, reasoning, cacheRead, cacheWrite]
    }

    private func json(_ rows: [[Any]]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!
    }

    func testParsesRowsAndBillsReasoningAsOutput() {
        let rows = OpenCodeOpenAIUsageScanner.parseRows(json([
            row(input: 100, output: 60, reasoning: 40, cacheRead: 30, cacheWrite: 20)
        ]))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].tokens, TokenBreakdown(
            input: 100, cacheWrite5m: 20, cacheRead: 30, output: 100
        ))
    }

    func testSkipsRowsWithoutTimestampAndMalformedPayload() {
        XCTAssertEqual(OpenCodeOpenAIUsageScanner.parseRows("not json"), [])
        let rows = OpenCodeOpenAIUsageScanner.parseRows(json([
            [NSNull(), "gpt-5.3-codex", 1, 2, 3, 4, 5],
            row(input: 10)
        ]))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].tokens.input, 10)
    }

    func testAggregatePricesKnownModels() throws {
        let scan = try XCTUnwrap(OpenCodeOpenAIUsageScanner.aggregate(
            rows: OpenCodeOpenAIUsageScanner.parseRows(json([
                row(input: 1_000_000),                       // 1M input @ $1000/M = $1000
                row(input: 0, output: 500_000, reasoning: 500_000)  // 1M output @ $3000/M = $3000 (reasoning included)
            ])),
            since: noon.addingTimeInterval(-86_400),
            pricing: pricing()
        ))
        let day = DailyUsageAccumulator.dayKey(from: noon)
        let entry = try XCTUnwrap(scan.series.daily.first { $0.date == day })
        XCTAssertEqual(try XCTUnwrap(entry.costUSD), 4000.0, accuracy: 0.0001)
        XCTAssertEqual(entry.totalTokens, 2_000_000)
    }

    func testUnknownModelExcludedFromTotalsButSurfacesWarning() throws {
        let scan = try XCTUnwrap(OpenCodeOpenAIUsageScanner.aggregate(
            rows: OpenCodeOpenAIUsageScanner.parseRows(json([
                row(model: "gpt-9000-mystery", input: 5)
            ])),
            since: noon.addingTimeInterval(-86_400),
            pricing: pricing()
        ))
        XCTAssertTrue(scan.series.daily.allSatisfy { $0.totalTokens == 0 })
        XCTAssertEqual(scan.unknownModelsByDay.values.flatMap(\.self).sorted(), ["gpt-9000-mystery"])
    }

    func testZeroTokenAndOutOfWindowRowsYieldNil() {
        XCTAssertNil(OpenCodeOpenAIUsageScanner.aggregate(
            rows: OpenCodeOpenAIUsageScanner.parseRows(json([
                row(input: 0),                                   // errored/aborted message
                row(msAgo: 40 * 86_400 * 1000, input: 100)       // outside the window
            ])),
            since: noon.addingTimeInterval(-86_400),
            pricing: pricing()
        ))
    }

    func testSQLFiltersToChatGPTPlanProviders() {
        let sql = OpenCodeOpenAIUsageScanner.dataSQL(cutoffMs: 123)
        XCTAssertTrue(sql.contains("IN ('openai','codex')"))
        XCTAssertTrue(sql.contains("time_created >= 123"))
        XCTAssertTrue(sql.contains("'$.role') = 'assistant'"))
    }
}

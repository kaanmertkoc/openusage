import XCTest
@testable import OpenUsage

final class MalformedUsageTokenTests: XCTestCase {
    func testTokenBoundaryRejectsInvalidValuesAndCapsBeforeConversion() {
        for value: Any in [-1, Double.nan, Double.infinity, "NaN", "broken", true, NSNull()] {
            XCTAssertEqual(UsageTokenCount.read(value, provider: "test"), 0)
        }
        XCTAssertEqual(UsageTokenCount.read(1e300, provider: "test"), UsageTokenCount.maximum)
        XCTAssertEqual(UsageTokenCount.read("42", provider: "test"), 42)
        XCTAssertEqual(UsageTokenCount.read(nil, provider: "test"), 0)
    }

    func testCodexMalformedBucketsCannotOverflowTheTotalOrDelta() {
        let first = CodexLogUsageScanner.RawUsage(json: [
            "input_tokens": 1e300, "output_tokens": 1e300, "reasoning_output_tokens": 1e300,
            "cached_input_tokens": -1
        ])
        XCTAssertEqual(first.input, UsageTokenCount.maximum)
        XCTAssertEqual(first.cached, 0)
        XCTAssertEqual(first.total, 3 * UsageTokenCount.maximum)
        let later = CodexLogUsageScanner.RawUsage(json: ["input_tokens": -1, "output_tokens": 10])
        XCTAssertEqual(later.subtracting(first).input, 0)
        XCTAssertEqual(later.subtracting(first).total, 0)
    }

    func testClaudeMalformedBucketsAreBoundedBeforeSummation() throws {
        let line = #"{"timestamp":"2026-09-23T12:00:00Z","message":{"model":"test","usage":{"input_tokens":1e300,"output_tokens":1e300,"cache_read_input_tokens":-2,"cache_creation_input_tokens":1e300}}}"#
        let entry = try XCTUnwrap(ClaudeLogUsageScanner.parseLine(Data(line.utf8)))
        XCTAssertEqual(entry.tokens.totalTokens, 3 * UsageTokenCount.maximum)
        XCTAssertEqual(entry.tokens.cacheRead, 0)
    }

    func testPiMalformedBucketsCannotTrapInIntConversion() throws {
        let line = #"{"type":"message","timestamp":"2026-09-23T12:00:00Z","message":{"role":"assistant","provider":"openai-codex","model":"test","usage":{"input":1e300,"output":-1,"cacheRead":1e300,"totalTokens":1e300}}}"#
        let entry = try XCTUnwrap(PiUsageScanner.parseLine(Data(line.utf8)))
        XCTAssertEqual(entry.tokens.totalTokens, 2 * UsageTokenCount.maximum)
        XCTAssertEqual(entry.reportedTotalTokens, UsageTokenCount.maximum)
    }

    func testGrokMalformedPIDAndTokensDoNotCrashOrCreateNegativeTotals() {
        let log = """
        {"ts":"2026-09-23T12:00:00Z","pid":1e300,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-09-23T12:00:00Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-09-23T12:01:00Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1e300,"cached_prompt_tokens":-1,"completion_tokens":1e300,"reasoning_tokens":-2}}
        """
        let scan = GrokLogUsageScanner.parse(log, since: .distantPast, pricing: TestPricing.bundled)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 2 * UsageTokenCount.maximum)
    }
}

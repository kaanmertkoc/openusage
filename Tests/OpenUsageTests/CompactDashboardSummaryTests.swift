import XCTest
@testable import OpenUsage

final class CompactDashboardSummaryTests: XCTestCase {
    func testMissingUsageNeverShowsSampleNumbers() {
        var missing = WidgetData(title: "Today", icon: .providerMark("claude"), kind: .dollars, used: 999)
        missing.hasData = false
        XCTAssertEqual(CompactDashboardSummary.text(for: [missing]), "Today: No data")
        XCTAssertEqual(CompactDashboardSummary.text(for: []), "No data")
    }

    func testSpendSummaryKeepsPeriodAndBothCostAndTokens() {
        var spend = WidgetData(title: "Today", icon: .providerMark("claude"), kind: .dollars, used: 0)
        spend.values = [
            MetricValue(number: 4.08, kind: .dollars),
            MetricValue(number: 1_200_000, kind: .count, label: "tokens")
        ]
        XCTAssertEqual(CompactDashboardSummary.text(for: [spend]), "Today: $4.08 · 1.2M tokens")
    }

    func testQuotaSummaryHonorsLeftModeAndSkipsCharts() {
        let session = WidgetData(
            title: "Session", icon: .providerMark("claude"), kind: .percent, used: 20,
            limit: 100, displayMode: .remaining
        )
        var chart = session
        chart.isChart = true
        XCTAssertEqual(CompactDashboardSummary.text(for: [chart, session]), "Session: 80% left")
        XCTAssertEqual(CompactDashboardSummary.text(for: [chart]), "Expand for Details")
    }
}

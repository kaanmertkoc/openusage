import Foundation

enum CompactDashboardSummary {
    /// Only summarize Always Visible metrics, in their saved order. Chart points and missing
    /// values must never be mistaken for a current token count or a measured zero.
    static func text(for metrics: [WidgetData]) -> String {
        let values = metrics.filter { !$0.isChart }.prefix(2)
        guard !values.isEmpty else {
            return metrics.contains(where: \.hasData) ? "Expand for Details" : WidgetData.noDataSubtitle
        }
        return values.map { data in
            let value = data.hasData
                ? (data.isBounded ? data.headline : data.unboundedDetail)
                : WidgetData.noDataSubtitle
            return "\(data.title): \(value)"
        }.joined(separator: " · ")
    }
}

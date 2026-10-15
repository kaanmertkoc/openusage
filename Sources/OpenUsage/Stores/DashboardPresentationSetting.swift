import Foundation

/// Presentation only: provider order, enabled metrics, and card expansion stay in LayoutStore.
enum DashboardPresentationSetting: String, CaseIterable {
    case list
    case cards

    static let key = "openusage.dashboard.presentation"

    var title: String {
        switch self {
        case .list: "List"
        case .cards: "Cards"
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .cards: "square.grid.2x2"
        }
    }
}

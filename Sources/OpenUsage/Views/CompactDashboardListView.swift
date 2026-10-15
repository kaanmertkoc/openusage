import SwiftUI

/// A short summary per provider; full metrics stay available by opening its row.
/// Expansion belongs to this view, so switching back to Cards preserves that layout.
struct CompactDashboardListView: View {
    @Environment(LayoutStore.self) private var layout

    var body: some View {
        VStack(spacing: 0) {
            ForEach(layout.displayGroups) { group in
                CompactProviderRow(group: group)
                if group.id != layout.displayGroups.last?.id {
                    Divider()
                }
            }
        }
    }
}

private struct CompactProviderRow: View {
    let group: ProviderGroup

    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var isExpanded = false

    private var providerID: String { group.provider.id }

    private struct ResolvedRow: Identifiable {
        let id: String
        let data: WidgetData
    }

    private var rows: [ResolvedRow] {
        group.widgets.compactMap { widget in
            layout.descriptor(for: widget).map {
                ResolvedRow(id: $0.id, data: dataStore.data(for: $0))
            }
        }
    }

    private var summary: String {
        if !rows.contains(where: { $0.data.hasData }), let notice = dataStore.headerNotice(for: providerID) {
            return notice
        }
        let metrics = group.alwaysShownWidgets.compactMap { widget in
            layout.descriptor(for: widget).map { dataStore.data(for: $0) }
        }
        return CompactDashboardSummary.text(for: metrics)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.spring) { isExpanded.toggle() }
            } label: {
                CompactProviderSummary(
                    provider: group.provider,
                    plan: dataStore.plan(for: providerID),
                    warning: dataStore.headerNotice(for: providerID),
                    refreshing: dataStore.refreshingProviderIDs.contains(providerID),
                    staleness: dataStore.stalenessHint(for: providerID),
                    summary: summary,
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.provider.displayName)
            .accessibilityValue(isExpanded ? "Expanded" : summary)
            .accessibilityHint(isExpanded ? "Collapse Usage Details" : "Expand Usage Details")
            .contextMenu { providerActions }

            if isExpanded {
                details
            }
        }
    }

    private var details: some View {
        let allRows = rows
        let visibleRows = allRows.contains(where: { $0.data.hasData }) ? allRows.filter(\.data.hasData) : allRows
        let condensed = WidgetData.condensedTextRowOffsets(in: visibleRows.map(\.data))
        return VStack(alignment: .leading, spacing: 0) {
            if let notice = dataStore.headerNotice(for: providerID) {
                Text(notice)
                    .font(.system(size: density.supportingPointSize))
                    .foregroundStyle(Theme.notice)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            ForEach(Array(visibleRows.enumerated()), id: \.element.id) { offset, row in
                WidgetRowView(
                    data: row.data,
                    onToggleResetDisplay: { dataStore.resetDisplayMode.toggle() },
                    onToggleMeterStyle: { dataStore.meterStyle.toggle() },
                    condensedTop: condensed.contains(offset)
                )
                .environment(\.codexResetClaim, providerID == "codex" ? container.codexResetClaim : nil)
                .environment(\.claudeResetClaim, container.claudeResetClaims[providerID])
            }
            if !group.provider.visibleLinks.isEmpty {
                ProviderLinksView(links: group.provider.visibleLinks)
            }
            HStack {
                Button("Refresh") {
                    Task { await dataStore.forceRefresh(providerID: providerID) }
                }
                Spacer()
                Button("Customize…", action: customize)
            }
            .buttonStyle(.plain)
            .font(.system(size: density.supportingPointSize))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var providerActions: some View {
        Button("Refresh \(group.provider.displayName)") {
            Task { await dataStore.forceRefresh(providerID: providerID) }
        }
        Button("Customize…", action: customize)
        Button("Share Screenshot") {
            _ = ShareCardRenderer.share(group: group, dataStore: dataStore, layout: layout, appearance: colorScheme)
        }
        Divider()
        Button("Hide \(group.provider.displayName)") {
            container.enablement.setEnabled(false, for: providerID)
        }
    }

    private func customize() {
        layout.customizeProviderID = providerID
        layout.isEditing = true
    }
}

struct CompactProviderSummary: View {
    let provider: Provider
    var plan: String?
    var warning: String?
    var refreshing = false
    var staleness: StalenessHint?
    let summary: String
    var isExpanded = false

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                ProviderSectionHeader(
                    provider: provider, plan: plan, warning: warning,
                    refreshing: refreshing, staleness: staleness
                )
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if !isExpanded {
                Text(summary)
                    .font(.system(size: density.supportingPointSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.leading, density.headerIconSize + 7)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

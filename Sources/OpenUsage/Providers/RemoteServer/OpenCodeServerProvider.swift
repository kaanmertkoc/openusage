import Foundation

/// OpenCode tile for the remote server, fed by the rsynced `opencode.db` copy (see
/// `RemoteServerSync`). The server's usage is subscription-billed ($0 cost rows), so the card shows
/// token tiles and a usage trend — no spend meters and no dollars.
@MainActor
final class OpenCodeServerProvider: ProviderRuntime {
    let provider = Provider(
        id: "opencode-server1",
        displayName: "OpenCode Server",
        icon: .providerMark("opencode"),
        links: [.init(label: "Docs", url: "https://opencode.ai/docs/")]
    )

    let syncRoot: URL
    let scanner: OpenCodeServerScanner
    let now: @Sendable () -> Date

    private let sourceNote = "From the \(RemoteServerSync.hostLabel) server's synced OpenCode logs"

    init(
        syncRoot: URL = RemoteServerSync.defaultRoot(),
        scanner: OpenCodeServerScanner = OpenCodeServerScanner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.syncRoot = syncRoot
        self.scanner = scanner
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [.usageTrend(provider: provider)] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // "Credentials" here is the sync marker: the tile is worth enabling once the server sync has
        // completed at least once.
        await loadOffMainActor { [syncRoot] in RemoteServerSync.lastSyncDate(root: syncRoot) != nil }
    }

    func refresh() async -> ProviderSnapshot {
        let refreshedAt = now()
        guard let lastSync = await loadOffMainActor({ [syncRoot] in
            RemoteServerSync.lastSyncDate(root: syncRoot)
        }) else {
            return ProviderSnapshot.error(provider: provider, error: RemoteServerSyncError.notSynced)
        }

        let series: DailyUsageSeries?
        do {
            series = try await loadOffMainActor { [scanner] in try scanner.scan(now: refreshedAt) }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        var lines: [MetricLine] = []
        if let series {
            // Tokens are measured (not priced), so nothing is flagged as estimated.
            SpendTileMapper.appendTokenUsage(series, to: &lines, now: refreshedAt, estimated: false)
            SpendTileMapper.appendUsageTrend(series, to: &lines, now: refreshedAt, note: sourceNote)
        }
        MetricLine.appendNoDataIfNeeded(&lines)
        return ProviderSnapshot.make(
            provider: provider,
            plan: nil,
            lines: lines,
            refreshedAt: refreshedAt,
            warning: RemoteServerSync.staleWarning(lastSync: lastSync, now: refreshedAt)
        )
    }
}

import Foundation

/// History-only Claude tile for the remote server: scans the rsynced copy of the server's
/// `~/.claude/projects` logs (see `RemoteServerSync`). No credentials and no live meters — the
/// session/weekly limits are account-wide and already live on the main Claude tile; this card only
/// answers "what did the server spend".
@MainActor
final class ClaudeServerProvider: ProviderRuntime {
    let provider = Provider(
        id: "claude-server1",
        displayName: "Claude Server",
        icon: .providerMark("claude"),
        links: [.init(label: "Status", url: "https://status.anthropic.com/")]
    )

    let syncRoot: URL
    let logUsageScanner: ClaudeLogUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    init(
        syncRoot: URL = RemoteServerSync.defaultRoot(),
        logUsageScanner: ClaudeLogUsageScanner? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.syncRoot = syncRoot
        // Pin the scan to the synced config dir. Cowork sandboxes belong to the local desktop app,
        // not the server — including them would double-book local usage into this tile.
        self.logUsageScanner = logUsageScanner ?? ClaudeLogUsageScanner(
            environment: OverriddenEnvironmentReader(
                overrides: ["CLAUDE_CONFIG_DIR": syncRoot.appendingPathComponent("claude").path]
            ),
            includeCoworkSandboxes: false
        )
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [.usageTrend(provider: provider)] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // "Credentials" here is the sync marker: the tile is worth enabling once the Claude leg of the
        // server sync has completed at least once, regardless of whether any logs came with it.
        await loadOffMainActor { [syncRoot] in
            RemoteServerSync.lastSyncDate(root: syncRoot, leg: .claude) != nil
        }
    }

    func refresh() async -> ProviderSnapshot {
        let refreshedAt = now()
        // Only the Claude leg's marker matters here: the opencode leg pulls a different dataset and its
        // failures must not age out this tile.
        guard let lastSync = await loadOffMainActor({ [syncRoot] in
            RemoteServerSync.lastSyncDate(root: syncRoot, leg: .claude)
        }) else {
            return ProviderSnapshot.error(provider: provider, error: RemoteServerSyncError.notSynced)
        }

        var lines: [MetricLine] = []
        let note = "From the \(RemoteServerSync.hostLabel) server's synced Claude logs (estimated)"
        if let scan = await logUsageScanner.scan(now: refreshedAt, pricing: await pricing()) {
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &lines, now: refreshedAt,
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: note
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: refreshedAt, note: note)
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

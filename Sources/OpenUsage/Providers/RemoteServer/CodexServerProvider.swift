import Foundation

/// History-only Codex tile for the remote server. It scans the synced copies of the server's Codex
/// rollout logs with the same native parser and pricing engine as the local Codex card. No remote
/// credentials are copied, and account-wide Session/Weekly limits remain on the local card.
@MainActor
final class CodexServerProvider: ProviderRuntime {
    let provider = Provider(
        id: "codex-server1",
        displayName: "Codex Server",
        icon: .providerMark("codex"),
        links: [
            .init(label: "Status", url: "https://status.openai.com/"),
            .init(label: "Dashboard", url: "https://chatgpt.com/codex/settings/usage")
        ]
    )

    let syncRoot: URL
    let logUsageScanner: CodexLogUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    init(
        syncRoot: URL = RemoteServerSync.defaultRoot(),
        logUsageScanner: CodexLogUsageScanner? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.syncRoot = syncRoot
        // Point the scanner at the synced rollout root only. The sync leg deliberately excludes
        // auth.json and config.toml, so the server account's credentials never leave the server.
        self.logUsageScanner = logUsageScanner ?? CodexLogUsageScanner(
            environment: OverriddenEnvironmentReader(
                overrides: ["CODEX_HOME": syncRoot.appendingPathComponent("codex").path]
            )
        )
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [.usageTrend(provider: provider)] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // The sync marker is this history-only provider's credential equivalent.
        await loadOffMainActor { [syncRoot] in
            RemoteServerSync.lastSyncDate(root: syncRoot, leg: .codex) != nil
        }
    }

    func refresh() async -> ProviderSnapshot {
        let refreshedAt = now()
        guard let lastSync = await loadOffMainActor({ [syncRoot] in
            RemoteServerSync.lastSyncDate(root: syncRoot, leg: .codex)
        }) else {
            return ProviderSnapshot.error(provider: provider, error: RemoteServerSyncError.notSynced)
        }

        var lines: [MetricLine] = []
        let note = "From the \(RemoteServerSync.hostLabel) server's synced Codex logs (estimated)"
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

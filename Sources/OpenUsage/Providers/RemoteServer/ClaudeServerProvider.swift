import Foundation

/// History-only Claude tile for the remote server: scans the rsynced copy of the server's
/// `~/.claude/projects` logs (see `RemoteServerSync`). No credentials and no live meters — the
/// session/weekly limits are account-wide and already live on the main Claude tile; this card only
/// answers "what did the server spend".
@MainActor
final class ClaudeServerProvider: ProviderRuntime {
    let provider: Provider
    let server: RemoteClaudeServer

    let syncRoot: URL
    let logUsageScanner: ClaudeLogUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    init(
        server: RemoteClaudeServer = RemoteClaudeServer.configured.first { $0.id == "server1" }!,
        syncRoot: URL? = nil,
        logUsageScanner: ClaudeLogUsageScanner? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.server = server
        self.provider = Provider(
            id: server.providerID,
            displayName: "Claude · \(server.name)",
            icon: .providerMark("claude"),
            links: [.init(label: "Status", url: "https://status.anthropic.com/")]
        )
        let syncRoot = syncRoot ?? server.syncRoot
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
        // Explicitly listed machines awaiting setup must be visible before their first sync.
        if server.setupRequired != nil { return true }
        // A configured server that has been attempted deserves a card even on failure, so a missing
        // folder or SSH problem is visible instead of silently hiding that machine.
        return await loadOffMainActor { [syncRoot] in
            RemoteServerSync.lastSyncDate(root: syncRoot, leg: .claude) != nil
                || FileManager.default.fileExists(atPath: syncRoot.appendingPathComponent("claude/.sync-error").path)
        }
    }

    func refresh() async -> ProviderSnapshot {
        if let message = server.setupRequired {
            AppLog.error(LogTag.plugin(provider.id), message)
            return ProviderSnapshot.error(provider: provider, message: message)
        }
        let refreshedAt = now()
        // Only the Claude leg's marker matters here: the opencode leg pulls a different dataset and its
        // failures must not age out this tile.
        let (lastSync, issue) = await loadOffMainActor { [syncRoot] in
            (RemoteServerSync.lastSyncDate(root: syncRoot, leg: .claude),
             RemoteServerSync.syncIssue(root: syncRoot, leg: .claude))
        }
        guard let lastSync else {
            let message = issue ?? "No synced Claude logs from \(server.name) yet. Run scripts/remote-sync.sh first."
            AppLog.error(LogTag.plugin(provider.id), message)
            return ProviderSnapshot.error(provider: provider, message: message)
        }

        var lines: [MetricLine] = []
        let note = "From \(server.name)'s synced Claude logs (estimated)"
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
            warning: issue ?? RemoteServerSync.staleWarning(lastSync: lastSync, now: refreshedAt)
        )
    }
}

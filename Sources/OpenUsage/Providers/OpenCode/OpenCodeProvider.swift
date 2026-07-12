import Foundation

/// Typed failures for the OpenCode provider, so telemetry groups them by a stable category
/// (see `ErrorCategory.swift`).
enum OpenCodeUsageError: Error, LocalizedError, Equatable {
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "OpenCode not detected. Log in with OpenCode Go or use OpenCode locally first."
        }
    }
}

/// Tracks OpenCode-hosted usage (the Go subscription + the Zen pay-as-you-go gateway) from OpenCode's
/// local SQLite logs. Cookie-free and network-free — see `OpenCodeUsageScanner`. The card shows the Go
/// plan caps as dollar meters plus honest local spend tiles + a usage trend.
@MainActor
final class OpenCodeProvider: ProviderRuntime {
    let provider = Provider(
        id: "opencode",
        displayName: "OpenCode",
        icon: .providerMark("opencode"),
        links: [
            .init(label: "Dashboard", url: "https://opencode.ai/auth")
        ]
    )

    let authStore: OpenCodeAuthStore
    let usageScanner: OpenCodeUsageScanner
    let now: @Sendable () -> Date

    /// Marks the dollars as derived from the user's local logs (they can only undercount true account
    /// usage), matching the other log-based providers' spend-tile note.
    private let sourceNote = "From your OpenCode logs (estimated)"

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        usageScanner: OpenCodeUsageScanner = OpenCodeUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageScanner = usageScanner
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        // Go plan caps read from local `opencode-go` spend (Session/Weekly above the fold, Monthly on
        // demand); the spend tiles + trend below sum combined OpenCode-hosted (Go + Zen) spend.
        [
            .boundedDollars(id: "opencode.session", provider: provider, title: "Session", limit: OpenCodeUsageMapper.sessionCap),
            .boundedDollars(id: "opencode.weekly", provider: provider, title: "Weekly", limit: OpenCodeUsageMapper.weeklyCap),
            .boundedDollars(id: "opencode.monthly", provider: provider, title: "Monthly", limit: OpenCodeUsageMapper.monthlyCap),
            .usageTrend(provider: provider)
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: the local `opencode-go` auth key, or any hosted usage already in
        // the local database. Local-only, off the main actor.
        await loadOffMainActor { [authStore, usageScanner] in
            if authStore.goAPIKey() != nil { return true }
            return usageScanner.hasHostedUsage()
        }
    }

    func refresh() async -> ProviderSnapshot {
        let hasGoKey = await loadOffMainActor { [authStore] in authStore.goAPIKey() != nil }

        guard let scan = await usageScanner.scan(now: now(), hasGoKey: hasGoKey) else {
            // No OpenCode database on disk. Logged-in-but-idle → "No usage data"; otherwise not logged in.
            guard hasGoKey else {
                return ProviderSnapshot.error(provider: provider, error: OpenCodeUsageError.notLoggedIn)
            }
            var lines: [MetricLine] = []
            MetricLine.appendNoDataIfNeeded(&lines)
            return ProviderSnapshot.make(provider: provider, plan: "Go", lines: lines, refreshedAt: now())
        }

        var lines: [MetricLine] = []
        if let windows = scan.goWindows {
            lines.append(contentsOf: OpenCodeUsageMapper.meterLines(windows))
        }
        SpendTileMapper.appendTokenUsage(
            scan.logScan.series, to: &lines, now: now(),
            unknownModelsByDay: scan.logScan.unknownModelsByDay,
            modelUsage: scan.logScan.modelUsage,
            modelSourceNote: sourceNote
        )
        SpendTileMapper.appendUsageTrend(scan.logScan.series, to: &lines, now: now(), note: sourceNote)
        MetricLine.appendNoDataIfNeeded(&lines)

        // `goWindows` is present only on a current Go signal (key or recent spend), never a stale anchor,
        // so it's the honest source for the plan badge too.
        let plan: String? = scan.goWindows != nil ? "Go" : nil
        return ProviderSnapshot.make(provider: provider, plan: plan, lines: lines, refreshedAt: now())
    }
}

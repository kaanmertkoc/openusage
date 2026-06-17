import XCTest
@testable import OpenUsage

@MainActor
final class WidgetDataStoreTests: XCTestCase {
    func testResolvesProgressSnapshotIntoWidgetData() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(
                    label: "Session",
                    used: 42,
                    limit: 100,
                    format: .percent,
                    resetsAt: Date(timeIntervalSinceNow: 60 * 60),
                    periodDurationMs: 5 * 60 * 60 * 1000
                )]
            )
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        // Hermetic: pin the meter style via an isolated suite so a persisted `.used` in `.standard`
        // can't flip the expected "remaining" output.
        let store = WidgetDataStore(registry: registry, providers: [runtime], defaults: makeUserDefaults("resolve-progress"))

        await store.refreshAll()
        let data = store.data(for: descriptor)

        XCTAssertEqual(data.used, 42)
        XCTAssertEqual(data.displayedValue, 58)
        XCTAssertEqual(data.valueText, "58%")
        XCTAssertEqual(data.boundedHeadline, "58% left")
        XCTAssertEqual(data.boundedSubtitle?.hasPrefix("Resets in "), true)
        XCTAssertEqual(store.menuBarPrimaryText, "58%")
    }

    func testRemainingProgressWithoutResetUsesPeriodDurationLabel() {
        let session = WidgetData(
            title: "Session",
            icon: .providerMark("claude"),
            kind: .percent,
            used: 0,
            limit: 100,
            displayMode: .remaining,
            resetsAt: nil,
            periodDurationMs: ClaudeUsageMapper.sessionPeriodMs
        )
        XCTAssertEqual(session.boundedSubtitle, "Resets in 5h")

        let weekly = WidgetData(
            title: "Weekly",
            icon: .providerMark("claude"),
            kind: .percent,
            used: 0,
            limit: 100,
            displayMode: .remaining,
            resetsAt: nil,
            periodDurationMs: ClaudeUsageMapper.weeklyPeriodMs
        )
        XCTAssertEqual(weekly.boundedSubtitle, "Resets in 7d")
    }

    func testDollarLimitSubtitleIsNotAReset() {
        // A dollar limit subtitle is not a reset countdown; it renders as plain "$<limit> limit" text.
        let onDemand = WidgetData(
            title: "On-demand", icon: .providerMark("cursor"),
            kind: .dollars, used: 0, limit: 100, limitNoun: "limit"
        )
        XCTAssertEqual(onDemand.boundedSubtitle, "$100 limit")
    }

    func testDonutFractionMatchesRoundedHeadline() {
        // 0.39% used reads "0%", so the ring must be empty (no sliver), not 0.0039.
        let nearlyZero = WidgetData(
            title: "Total usage",
            icon: .providerMark("cursor"),
            kind: .percent,
            used: 0.3915,
            limit: 100
        )
        XCTAssertEqual(nearlyZero.valueText, "0%")
        XCTAssertEqual(nearlyZero.fraction, 0, accuracy: 0.0001)

        // 0.6% rounds up to "1%", so the ring should match that 1%.
        let roundsUp = WidgetData(
            title: "Total usage",
            icon: .providerMark("cursor"),
            kind: .percent,
            used: 0.6,
            limit: 100
        )
        XCTAssertEqual(roundsUp.valueText, "1%")
        XCTAssertEqual(roundsUp.fraction, 0.01, accuracy: 0.0001)

        // 99.6% used reads "100%", so the ring should be full.
        let nearlyFull = WidgetData(
            title: "Total usage",
            icon: .providerMark("cursor"),
            kind: .percent,
            used: 99.6,
            limit: 100
        )
        XCTAssertEqual(nearlyFull.valueText, "100%")
        XCTAssertEqual(nearlyFull.fraction, 1, accuracy: 0.0001)
    }

    func testOnDemandDollarLimitAppendsLimitNoun() {
        let onDemand = WidgetData(
            title: "On-Demand",
            icon: .providerMark("cursor"),
            kind: .dollars,
            used: 0,
            limit: 100,
            limitNoun: "limit"
        )
        XCTAssertEqual(onDemand.boundedSubtitle, "$100 limit")
    }

    func testCreditsDollarLimitAppendsLimitNoun() {
        // Matches the original OpenUsage, which renders every bounded dollar metric's subtitle as
        // "$X limit" — never "total".
        let credits = WidgetData(
            title: "Credits",
            icon: .providerMark("cursor"),
            kind: .dollars,
            used: 0,
            limit: 20,
            limitNoun: "limit"
        )
        XCTAssertEqual(credits.boundedSubtitle, "$20 limit")
    }

    func testRequestsShowsBillingResetInsteadOfSuffix() {
        // The requests tile resets on the billing cycle, so it shows the cadence rather than "requests".
        let requests = WidgetData(
            title: "Requests",
            icon: .providerMark("cursor"),
            kind: .count,
            used: 0,
            limit: 500,
            countSuffix: "requests",
            periodDurationMs: CursorUsageMapper.billingPeriodMs
        )
        XCTAssertEqual(requests.boundedSubtitle, "Resets in 30d")
    }

    func testCreditsRenderDollarValueWithRawCountInvariantToMeterStyle() async {
        // Codex flex credits lead with the dollar value (4¢/credit): the provider line arrives as
        // "$40.00 · 1,000 credits" and the row shows it verbatim (no Used/Left flipping), while the
        // parsed dollar amount still feeds the menu bar's compact value.
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "codex.credits",
            providerID: provider.id,
            metricLabel: "Credits",
            sample: {
                var sample = WidgetData(
                    title: "Extra Usage",
                    icon: provider.icon,
                    kind: .dollars,
                    used: 0,
                    limit: nil
                )
                sample.preservesRawText = true
                return sample
            }()
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.text(label: "Credits", value: CodexUsageMapper.creditsLabel(remaining: 1000))]
            )
        )
        let defaults = makeUserDefaults("codex-credits")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        XCTAssertFalse(remaining.isBounded)
        XCTAssertEqual(remaining.unboundedDetail, "$40.00 · 1,000 credits")
        XCTAssertEqual(remaining.used, 40.0)   // parsed dollars → compact tray value
        XCTAssertNil(remaining.unboundedSubtitle)

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.unboundedDetail, remaining.unboundedDetail)
        XCTAssertEqual(used.headline, remaining.headline)
    }

    func testRateLimitResetsTileShowsCountInTrayAndRawTextInPopover() async {
        // Regression: the menu-bar tile and the popover row must resolve from one value. The provider
        // line is "1 available" — the popover shows it verbatim while the tray uses the parsed count.
        // A prior bug backed the tile with display text only, leaving `used` at 0, so a pinned tile
        // read "0" while the popover correctly read "1 available".
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.verbatimCount(
            id: "codex.rateLimitResets",
            provider: provider,
            title: "Rate Limit Resets",
            metricLabel: "Rate Limit Resets"
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.text(label: "Rate Limit Resets", value: "1 available")]
            )
        )
        let defaults = makeUserDefaults("codex-resets")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.hasData)
        XCTAssertFalse(data.isBounded)
        XCTAssertEqual(data.unboundedDetail, "1 available")   // popover row
        XCTAssertEqual(data.displayedValue, 1)                // menu-bar tile's compact value
    }

    func testCreditsLabelFloorsAndClampsBalance() {
        XCTAssertEqual(CodexUsageMapper.creditsLabel(remaining: 820.9), "$32.80 · 820 credits")
        XCTAssertEqual(CodexUsageMapper.creditsLabel(remaining: -5), "$0.00 · 0 credits")
    }

    func testCreditsRenderUpToOneDecimalPlace() {
        let credits = WidgetData(
            title: "Extra Usage",
            icon: .providerMark("codex"),
            kind: .count,
            used: 820.55,
            limit: nil,
            countSuffix: "credits",
            unboundedValueWord: "left"
        )

        XCTAssertEqual(credits.valueText, "820.6")
        XCTAssertEqual(credits.unboundedDetail, "820.6 credits left")
    }

    func testCcusageAmountTilesShowLocalEstimateWithAndWithoutSpend() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let sample = { (id: String, title: String) in
            WidgetDescriptor(
                id: id,
                providerID: provider.id,
                metricLabel: title,
                sample: WidgetData(
                    title: title,
                    icon: provider.icon,
                    kind: .dollars,
                    used: 0,
                    limit: nil,
                    unboundedValueWord: "spent",
                    infoNote: WidgetData.ccusageEstimateNote
                )
            )
        }
        let last30 = sample("test.last30", "Last 30 Days")
        let today = sample("test.today", "Today")
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [last30, today],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [
                    .text(label: "Last 30 Days", value: "$478.00 · 891K tokens"),
                    .text(label: "Today", value: "0 tokens")
                ]
            )
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: [last30, today])
        let cache = ProviderSnapshotCache(
            userDefaults: makeUserDefaults("ccusage-estimate"),
            storageKey: "snapshots",
            ttl: 600,
            now: { Date() }
        )
        let store = WidgetDataStore(registry: registry, providers: [runtime], cache: cache)
        await store.refreshAll()

        let last30Data = store.data(for: last30)
        XCTAssertEqual(last30Data.valueText, "$478.00")
        XCTAssertEqual(last30Data.infoNote, WidgetData.ccusageEstimateNote)
        XCTAssertNil(last30Data.unboundedSubtitle)

        let todayData = store.data(for: today)
        XCTAssertEqual(todayData.valueText, "$0.00")
        XCTAssertEqual(todayData.infoNote, WidgetData.ccusageEstimateNote)
    }

    /// `resolveText` builds the resolved row from the descriptor's sample but must reset the fields a
    /// fresh text row never inherits (here `preservesRawText`, `limitNoun`, `resetsAt`,
    /// `periodDurationMs`) to their `WidgetData` defaults — otherwise a verbatim-dollars sample would
    /// leak its raw-text flag and a stray limit noun into the resolved value.
    func testResolveTextResetsNonInheritedSampleFields() async {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        var sample = WidgetData(title: "Extra Usage", icon: provider.icon, kind: .dollars, used: 0, limit: nil)
        sample.preservesRawText = true
        sample.limitNoun = "cap"
        sample.resetsAt = Date(timeIntervalSince1970: 1_800_000_000)
        sample.periodDurationMs = 123_456
        let descriptor = WidgetDescriptor(id: "codex.credits", providerID: provider.id,
                                          metricLabel: "Credits", sample: sample)
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.text(label: "Credits", value: "$40.00 · 1,000 credits")]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            defaults: makeUserDefaults("resolve-text-reset")
        )
        await store.refreshAll()
        let data = store.data(for: descriptor)

        XCTAssertEqual(data.used, 40.0)
        // preservesRawText still drives the verbatim override above, but the resolved row's own flag
        // resets to its default.
        XCTAssertFalse(data.preservesRawText)
        XCTAssertEqual(data.valueTextOverride, "$40.00 · 1,000 credits")
        XCTAssertNil(data.limitNoun)
        XCTAssertNil(data.resetsAt)
        XCTAssertNil(data.periodDurationMs)
    }

    /// A `.percent` text row defaults a missing sample limit to a 100 scale and never carries an
    /// `unboundedValueWord`, even when the sample (incorrectly) had one.
    func testResolveTextPercentDefaultsLimitAndDropsUnboundedWord() async {
        let provider = Provider(id: "p", displayName: "P", icon: .providerMark("p"))
        var sample = WidgetData(title: "Usage", icon: provider.icon, kind: .percent, used: 0, limit: nil)
        sample.unboundedValueWord = "left"
        let descriptor = WidgetDescriptor(id: "p.usage", providerID: provider.id,
                                          metricLabel: "Usage", sample: sample)
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.text(label: "Usage", value: "42")]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            defaults: makeUserDefaults("resolve-text-percent")
        )
        await store.refreshAll()
        let data = store.data(for: descriptor)

        XCTAssertEqual(data.used, 42)
        XCTAssertEqual(data.limit, 100)
        XCTAssertNil(data.unboundedValueWord)
    }

    func testUsesFreshCachedSnapshotInsteadOfRefreshingProvider() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ProviderSnapshotCache(
            userDefaults: makeUserDefaults("fresh-cache"),
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-60)
        ))
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 80, limit: 100, format: .percent)],
                refreshedAt: now
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: makeUserDefaults("fresh-cache-meter")
        )

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 0)
        XCTAssertEqual(store.data(for: descriptor).valueText, "80%")
    }

    func testExpiredCacheRefreshesAndReplacesSnapshot() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let defaults = makeUserDefaults("expired-cache")
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-601)
        ))
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 80, limit: 100, format: .percent)],
                refreshedAt: now
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: makeUserDefaults("expired-cache-meter")
        )

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.data(for: descriptor).valueText, "20%")
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

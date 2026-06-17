import Foundation

/// Shared descriptor factories — the one place that knows how a descriptor's sample `WidgetData`
/// is assembled, so a provider declares its gallery as a flat list instead of re-implementing the
/// same private builders. Sample numbers are structural only (a row without real data renders the
/// no-data marker, never the sample), so every factory seeds `used: 0`.
extension WidgetDescriptor {
    /// Bounded 0–100% meter (session/weekly-style quotas).
    static func percent(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .percent, used: 0, limit: 100))
    }

    /// Bounded dollar meter whose subtitle reads "$<limit> <limitNoun>" (noun defaults to "limit").
    static func boundedDollars(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        limit: Double,
        limitNoun: String? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .dollars, used: 0, limit: limit, limitNoun: limitNoun))
    }

    /// Bounded count meter (e.g. requests per billing cycle). `periodDurationMs` lets the subtitle
    /// show the cycle's reset cadence instead of the bare suffix.
    static func boundedCount(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        limit: Double,
        suffix: String,
        periodDurationMs: Int? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .count, used: 0, limit: limit, countSuffix: suffix,
                                periodDurationMs: periodDurationMs))
    }

    /// Unbounded spend tile reading "$12.34 spent". `estimated` adds the ⓘ explaining the number
    /// is imputed locally (ccusage) rather than billed; server-backed spend stays clean.
    static func spend(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        estimated: Bool = false
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .dollars, used: 0, limit: nil,
                                unboundedValueWord: "spent",
                                infoNote: estimated ? WidgetData.ccusageEstimateNote : nil))
    }

    /// Unbounded dollar balance with a custom trailing word (e.g. "$1,503.00 left").
    static func dollarBalance(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        valueWord: String
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .dollars, used: 0, limit: nil, unboundedValueWord: valueWord))
    }

    /// Unbounded dollar row rendered verbatim from the provider's `.text` line (e.g. Codex credits
    /// "$32.84 · 821 credits"); the parsed dollars still feed the menu-bar compact value.
    static func verbatimDollars(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil
    ) -> WidgetDescriptor {
        var sample = WidgetData(title: title, icon: provider.icon,
                                kind: .dollars, used: 0, limit: nil)
        sample.preservesRawText = true
        return make(id: id, provider: provider, metricLabel: metricLabel ?? title, sample: sample)
    }

    /// Unbounded count rendered verbatim from the provider's `.text` line (e.g. Codex rate-limit
    /// resets "1 available"); the parsed count still feeds the menu-bar tile's compact value, so the
    /// tray and the popover never diverge.
    static func verbatimCount(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil
    ) -> WidgetDescriptor {
        var sample = WidgetData(title: title, icon: provider.icon,
                                kind: .count, used: 0, limit: nil)
        sample.preservesRawText = true
        return make(id: id, provider: provider, metricLabel: metricLabel ?? title, sample: sample)
    }

    /// Unbounded count resolved from a provider `.badge` line via `valueTextOverride`
    /// (e.g. Grok pay-as-you-go).
    static func badge(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .count, used: 0, limit: nil))
    }

    private static func make(
        id: String,
        provider: Provider,
        metricLabel: String,
        sample: WidgetData
    ) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: metricLabel,
            sample: sample
        )
    }
}

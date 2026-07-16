import Foundation

/// Attributes ChatGPT-plan usage that happened inside OpenCode back to the Codex card.
///
/// OpenCode's local SQLite logs record per-message token counts for the `openai`/`codex` OAuth
/// providers, but always with `cost: 0` — OpenCode has no pricing for subscription usage — and the
/// OpenCode card deliberately tracks only OpenCode's own hosted gateways. Without this scan, plan
/// usage driven through OpenCode consumes the Codex card's Session/Weekly meters while its spend
/// tiles read $0. Tokens are re-priced through the shared pricing store, exactly like the Codex
/// CLI's own rollouts; reasoning tokens bill at the output rate.
///
/// Best-effort and supplementary: any read failure logs and yields `nil`, so the Codex card still
/// renders its native CLI scan. No dedup against the CLI scan is needed — OpenCode messages and
/// Codex CLI rollouts are disjoint logs.
struct OpenCodeOpenAIUsageScanner: Sendable {
    /// OpenCode auth providerIDs that ride the user's ChatGPT plan.
    static let chatGPTProviderIDs = ["openai", "codex"]

    var sqlite: SQLiteAccessing
    var databasePaths: @Sendable () throws -> [String]

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = OpenCodeUsageScanner.defaultDatabasePaths
    ) {
        self.sqlite = sqlite
        self.databasePaths = databasePaths
    }

    /// Scan the last `daysBack` days of OpenCode's ChatGPT-plan messages. Returns `nil` when there
    /// is no OpenCode database, no readable rows, or no plan usage at all — the caller's merge then
    /// leaves the Codex card exactly as the native scan built it.
    func scan(now: Date, daysBack: Int = 30, pricing: ModelPricing) async -> LogUsageScan? {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            AppLog.warn(LogTag.plugin("codex"), "opencode usage scan: data directory unreadable: \(error.localizedDescription)")
            return nil
        }
        guard !paths.isEmpty else { return nil }

        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cutoffMs = Int(since.timeIntervalSince1970 * 1000)
        var rows: [Row] = []
        for path in paths {
            do {
                if let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs)) {
                    rows.append(contentsOf: Self.parseRows(json))
                }
            } catch {
                AppLog.warn(LogTag.plugin("codex"), "opencode usage query failed for \(path): \(error.localizedDescription)")
            }
        }
        guard !rows.isEmpty else { return nil }
        return Self.aggregate(rows: rows, since: since, pricing: pricing)
    }

    // MARK: - Parsing

    struct Row: Equatable, Sendable {
        var ms: Double
        var model: String
        var tokens: TokenBreakdown
    }

    /// Parse the `json_group_array(json_array(...))` payload: an array of
    /// `[time_created, modelID, input, output, reasoning, cacheRead, cacheWrite]`. Rows missing a
    /// timestamp are skipped at this boundary; aborted/errored messages carry zeroed tokens and
    /// fall out in aggregation.
    static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }

        var rows: [Row] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 7,
                  let ms = ProviderParse.number(entry[0])
            else { continue }
            // Clamp before Int conversion so a corrupt, absurdly large count can't trap.
            func tokenCount(_ value: Any) -> Int {
                Int(min(max(ProviderParse.number(value) ?? 0, 0), 1e15))
            }
            rows.append(Row(
                ms: ms,
                model: (entry[1] as? String) ?? "",
                tokens: TokenBreakdown(
                    input: tokenCount(entry[2]),
                    cacheWrite5m: tokenCount(entry[6]),
                    cacheRead: tokenCount(entry[5]),
                    // OpenAI bills reasoning tokens at the output rate.
                    output: tokenCount(entry[3]) + tokenCount(entry[4])
                )
            ))
        }
        return rows
    }

    /// Bucket rows into local calendar days, pricing each through the shared store. Mirrors the
    /// Claude/Codex scanners' unknown-model rule: an unpriceable row is excluded from every total
    /// and surfaces only via the unknown-model warning, so measured and unpriceable tokens never mix.
    static func aggregate(rows: [Row], since: Date, pricing: ModelPricing) -> LogUsageScan? {
        var accumulator = DailyUsageAccumulator()
        var sawUsage = false
        for row in rows {
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            guard date >= since, row.tokens.totalTokens > 0 else { continue }
            let day = DailyUsageAccumulator.dayKey(from: date)
            guard let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { continue }
            // Session-level token sums do not preserve request boundaries, so long-context tiers
            // stay off — same rule as other aggregated sources.
            guard let cost = pricing.estimatedCostDollars(model: model, tokens: row.tokens, applyLongContextRates: false) else {
                accumulator.addUnknownModel(day: day, model: model)
                sawUsage = true
                continue
            }
            accumulator.add(day: day, tokens: row.tokens.totalTokens, cost: cost, model: model)
            sawUsage = true
        }
        return sawUsage ? accumulator.build() : nil
    }

    // MARK: - SQL

    private static let providerFilter = "(" + chatGPTProviderIDs.map { "'\($0)'" }.joined(separator: ",") + ")"

    static func dataSQL(cutoffMs: Int) -> String {
        """
        SELECT json_group_array(json_array(
                 time_created,
                 json_extract(data,'$.modelID'),
                 COALESCE(json_extract(data,'$.tokens.input'),0),
                 COALESCE(json_extract(data,'$.tokens.output'),0),
                 COALESCE(json_extract(data,'$.tokens.reasoning'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.read'),0),
                 COALESCE(json_extract(data,'$.tokens.cache.write'),0)))
        FROM message
        WHERE time_created >= \(cutoffMs)
          AND json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') IN \(providerFilter);
        """
    }
}

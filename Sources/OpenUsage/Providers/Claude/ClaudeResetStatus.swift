import Foundation

/// Claude's reset grants are identified by ID, not expiry: grants may share a deadline or hold
/// multiple uses. Read-only snapshots and the claim preflight decode the same representation.
struct ClaudeResetStatus: Decodable, Equatable, Sendable {
    struct Grant: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let label: String
        let resetsLeft: Int
        let startsAt: Date?
        let endsAt: Date?
        let clears: [String]
        let paused: Bool
        let usableNow: Bool
        let useRequiresLimit: Bool
        let blocking: [String]

        private enum CodingKeys: String, CodingKey {
            case id, label, clears, paused, blocking
            case resetsLeft = "resets_left", startsAt = "starts_at", endsAt = "ends_at"
            case usableNow = "usable_now", useRequiresLimit = "use_requires_limit"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            resetsLeft = try c.decode(Int.self, forKey: .resetsLeft)
            guard id.range(of: #"^[a-z0-9_-]{1,40}$"#, options: .regularExpression) != nil,
                  (0...1000).contains(resetsLeft) else { throw ClaudeUsageError.invalidResponse }
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Usage Limit Reset"
            startsAt = try Self.date(c, .startsAt)
            endsAt = try Self.date(c, .endsAt)
            clears = try c.decodeIfPresent([String].self, forKey: .clears) ?? []
            paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
            usableNow = try c.decodeIfPresent(Bool.self, forKey: .usableNow) ?? false
            useRequiresLimit = try c.decodeIfPresent(Bool.self, forKey: .useRequiresLimit) ?? true
            blocking = try c.decodeIfPresent([String].self, forKey: .blocking) ?? []
        }

        private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date? {
            guard let raw = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
            guard let date = OpenUsageISO8601.date(from: raw) else { throw ClaudeUsageError.invalidResponse }
            return date
        }

        var limitsDescription: String {
            clears.map { Self.limitNames[$0] ?? $0 }.joined(separator: ", ")
        }

        static let limitNames = [
            "five_hour": "Session", "seven_day": "Weekly",
            "seven_day_overage_included": "Included Models Weekly",
            "seven_day_opus": "Opus Weekly", "seven_day_sonnet": "Sonnet Weekly",
            "seven_day_cowork": "Cowork Weekly", "seven_day_omelette": "Weekly Model Limit",
            "seven_day_oauth_apps": "Connected Apps Weekly"
        ]
    }

    let eligible: Bool
    let atLimit: Bool?
    let grants: [Grant]?
    let nextGrantID: String?
    let cooldownUntil: String?

    private enum CodingKeys: String, CodingKey {
        case eligible, grants
        case atLimit = "at_limit", nextGrantID = "next_grant_id", cooldownUntil = "cooldown_until"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eligible = try c.decode(Bool.self, forKey: .eligible)
        atLimit = try c.decodeIfPresent(Bool.self, forKey: .atLimit)
        grants = try c.decodeIfPresent([Grant].self, forKey: .grants)
        nextGrantID = try c.decodeIfPresent(String.self, forKey: .nextGrantID)
        cooldownUntil = try c.decodeIfPresent(String.self, forKey: .cooldownUntil)
        let ids = (grants ?? []).map(\.id)
        guard ids.count <= 1000, Set(ids).count == ids.count else { throw ClaudeUsageError.invalidResponse }
    }

    func availableGrants(now: Date) -> [Grant] {
        (grants ?? []).filter { $0.resetsLeft > 0 && ($0.endsAt == nil || $0.endsAt! > now) }
            .sorted { ($0.endsAt ?? .distantFuture, $0.id) < ($1.endsAt ?? .distantFuture, $1.id) }
    }

    func unavailableReason(for grant: Grant, now: Date) -> String? {
        if !eligible { return "This account is not eligible." }
        if grant.resetsLeft == 0 { return "This reset has already been used." }
        if let end = grant.endsAt, end <= now { return "This reset has expired." }
        if let start = grant.startsAt, start > now { return "This reset is not available yet." }
        if grant.paused { return "Anthropic has paused this reset." }
        if let raw = cooldownUntil {
            guard let date = OpenUsageISO8601.date(from: raw) else { return "Reset status is unavailable." }
            if date > now { return "Please wait for the reset cooldown to finish." }
        }
        if nextGrantID != grant.id { return "Use the earlier reset first." }
        if grant.clears.isEmpty || grant.clears.contains(where: { Grant.limitNames[$0] == nil }) {
            return "This reset affects limits this app does not recognize yet. Use Claude's Usage settings."
        }
        if grant.useRequiresLimit && atLimit != true { return "Available when you reach a usage limit." }
        if !grant.blocking.isEmpty || !grant.usableNow { return "Anthropic says this reset cannot be used yet." }
        return nil
    }

    static func fromUsage(_ response: HTTPResponse) throws -> Self? {
        guard (200..<300).contains(response.statusCode) else { throw ClaudeUsageError.requestFailed(response.statusCode) }
        struct Envelope: Decodable { let cedar_ember: ClaudeResetStatus? }
        return try JSONDecoder().decode(Envelope.self, from: response.body).cedar_ember
    }
}

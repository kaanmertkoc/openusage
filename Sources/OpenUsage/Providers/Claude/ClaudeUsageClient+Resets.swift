import Foundation

extension ClaudeUsageClient {
    static let resetUserAgent = "claude-cli/2.1.281 (external, cli)"

    static func usageURLWithResetGrants(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "cedar_ember" }
            + [URLQueryItem(name: "cedar_ember", value: "1")]
        return components.url!
    }

    struct ResetIdentity: Codable, Equatable, Sendable {
        let accountID: String
        let organizationID: String
    }

    func fetchResetIdentity(accessToken: String, config: ClaudeOAuthConfig) async throws -> ResetIdentity {
        let response = try await httpClient.send(HTTPRequest(
            method: "GET", url: config.usageURL.deletingLastPathComponent().appendingPathComponent("profile"),
            headers: Self.resetHeaders(accessToken), timeout: 10
        ))
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let account = body["account"] as? [String: Any], let accountID = account["uuid"] as? String,
              let org = body["organization"] as? [String: Any], let organizationID = org["uuid"] as? String,
              UUID(uuidString: accountID) != nil, UUID(uuidString: organizationID) != nil
        else { throw ClaudeUsageError.invalidResponse }
        return ResetIdentity(accountID: accountID.lowercased(), organizationID: organizationID.lowercased())
    }

    /// The only Claude reset mutation. No retry, credential fallback, or automatic invocation.
    /// Matches Claude Code 2.1.281's grant-specific request and idempotency key.
    func redeemReset(
        accessToken: String, config: ClaudeOAuthConfig, identity: ResetIdentity,
        grantID: String, requestID: String
    ) async throws -> HTTPResponse {
        guard UUID(uuidString: identity.organizationID) != nil,
              grantID.range(of: #"^[a-z0-9_-]{1,40}$"#, options: .regularExpression) != nil,
              requestID.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil
        else { throw ClaudeUsageError.invalidResponse }
        var components = URLComponents(url: config.usageURL, resolvingAgainstBaseURL: false)!
        components.path = "/api/organizations/\(identity.organizationID)/reset_rate_limits"
        components.query = nil
        components.fragment = nil
        let body = try JSONSerialization.data(withJSONObject: [
            "program": "cedar_ember", "grant_id": grantID, "request_id": requestID
        ])
        return try await httpClient.send(HTTPRequest(
            method: "POST", url: components.url!, headers: Self.resetHeaders(accessToken), body: body, timeout: 25
        ))
    }

    private static func resetHeaders(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))",
         "Accept": "application/json", "Content-Type": "application/json",
         "anthropic-beta": "oauth-2025-04-20", "User-Agent": resetUserAgent]
    }
}

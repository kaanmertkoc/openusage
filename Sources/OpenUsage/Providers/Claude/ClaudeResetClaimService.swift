import Foundation
import Observation
import SwiftUI

struct ClaudeResetCredentials: Equatable, Sendable {
    let accessToken: String
    let config: ClaudeOAuthConfig
}

/// Read on open, prepare on Use, mutate only on Confirm. The saved unresolved attempt contains no
/// credentials and survives app restarts, so an uncertain response cannot silently mint a new request.
@MainActor @Observable
final class ClaudeResetClaimService {
    struct Confirmation: Codable, Equatable {
        let identity: ClaudeUsageClient.ResetIdentity
        let usageURL: URL
        let grantID: String
        let label: String
        let limits: [String]
        let expiresAt: Date?
        let requestID: String
    }

    private struct Session {
        let credentials: ClaudeResetCredentials
        let identity: ClaudeUsageClient.ResetIdentity
        let status: ClaudeResetStatus
        let loadedAt: Date
    }

    let displayName: String
    private(set) var status: ClaudeResetStatus?
    private(set) var confirmation: Confirmation?
    private(set) var unresolved: Confirmation?
    private(set) var message: String?
    private(set) var isLoading = false
    private(set) var isClaiming = false
    private let providerID: String
    private let client: ClaudeUsageClient
    private let credentials: () async -> ClaudeResetCredentials?
    private let refreshAfterClaim: () async -> Void
    private let now: () -> Date
    private let defaults: UserDefaults
    private let storageKey: String
    private var storageUnreadable = false
    private var session: Session?

    init(
        providerID: String, displayName: String, client: ClaudeUsageClient,
        defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
        credentials: @escaping () async -> ClaudeResetCredentials?,
        refreshAfterClaim: @escaping () async -> Void = {}
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.client = client
        self.defaults = defaults
        self.now = now
        self.credentials = credentials
        self.refreshAfterClaim = refreshAfterClaim
        storageKey = "openusage.claudeReset.pending.\(providerID)"
        if let data = defaults.data(forKey: storageKey) {
            do { unresolved = try JSONDecoder().decode(Confirmation.self, from: data) }
            catch {
                storageUnreadable = true
                AppLog.error(LogTag.plugin(providerID), "Cannot read saved reset attempt; redemption disabled")
            }
        }
    }

    var grants: [ClaudeResetStatus.Grant] { status?.availableGrants(now: now()) ?? [] }

    func unavailableReason(_ grant: ClaudeResetStatus.Grant) -> String? {
        if storageUnreadable { return "The saved reset attempt could not be read. Use Claude's Usage settings." }
        if unresolved != nil { return "Resolve the previous reset request first." }
        guard let session, now().timeIntervalSince(session.loadedAt) < 60 else { return "Refresh reset status first." }
        return session.status.unavailableReason(for: grant, now: now())
    }

    /// Safe GETs only. A cached quota card is never enough to authorize a write.
    func load() async {
        guard !isClaiming, !isLoading else { return }
        isLoading = true
        confirmation = nil
        message = nil
        defer { isLoading = false }
        do {
            let loaded = try await fetchSession()
            session = loaded
            status = loaded.status
            if storageUnreadable { message = "The saved reset attempt could not be read. Use Claude's Usage settings." }
        } catch {
            session = nil
            message = "Could not check resets. Refresh this account and try again."
            AppLog.error(LogTag.plugin(providerID), "Reset status check failed: \(error.localizedDescription)")
        }
    }

    func prepare(grantID: String) {
        guard !isLoading, !isClaiming, let session,
              let grant = grants.first(where: { $0.id == grantID }), unavailableReason(grant) == nil else { return }
        message = nil
        confirmation = Confirmation(
            identity: session.identity, usageURL: session.credentials.config.usageURL,
            grantID: grant.id, label: grant.label, limits: grant.clears, expiresAt: grant.endsAt,
            requestID: UUID().uuidString
        )
    }

    /// An explicit retry still requires confirmation. It reuses the exact account, grant and request ID.
    func prepareRetry() {
        guard !storageUnreadable, !isLoading, !isClaiming, let unresolved else { return }
        confirmation = unresolved
        message = nil
    }

    func cancel() { confirmation = nil }

    func confirm() async {
        guard !isLoading, !isClaiming, !storageUnreadable, let selected = confirmation else { return }
        confirmation = nil // Consumed before the first await: repeated clicks cannot send another request.
        isClaiming = true
        message = nil
        defer { isClaiming = false }
        var sent = false
        do {
            let fresh = try await fetchSession()
            session = fresh
            status = fresh.status
            guard fresh.identity == selected.identity, fresh.credentials.config.usageURL == selected.usageURL else {
                throw ClaimError.accountChanged
            }
            if unresolved == nil {
                guard let grant = fresh.status.availableGrants(now: now()).first(where: { $0.id == selected.grantID }),
                      fresh.status.unavailableReason(for: grant, now: now()) == nil,
                      grant.clears == selected.limits, grant.endsAt == selected.expiresAt
                else { throw ClaimError.grantChanged }
            } else if unresolved != selected {
                throw ClaimError.grantChanged
            }
            // Recheck the provider's credential generation after the network preflight. Never fall back
            // to a different login when a write fails, even if another credential can read usage.
            guard await credentials() == fresh.credentials else { throw ClaimError.accountChanged }
            let data = try JSONEncoder().encode(selected)
            defaults.set(data, forKey: storageKey)
            guard defaults.synchronize(), defaults.data(forKey: storageKey) == data else { throw ClaimError.storageFailed }
            unresolved = selected
            sent = true
            let response = try await client.redeemReset(
                accessToken: fresh.credentials.accessToken, config: fresh.credentials.config,
                identity: selected.identity, grantID: selected.grantID, requestID: selected.requestID
            )
            guard (200..<300).contains(response.statusCode), let body = ProviderParse.jsonObject(response.body),
                  let result = body["result"] as? String else { throw ClaimError.uncertain }
            let reason = body["reason"] as? String
            guard reason != "stamp_indeterminate", reason != "reset_unconfirmed" else { throw ClaimError.uncertain }
            switch result {
            case "reset": message = "Reset used for \(displayName)."
            case "already_used": message = "This reset request was already used."
            case "not_limited": message = "Claude says there is no eligible limit to reset."
            case "cooldown": message = "Please wait for Claude's reset cooldown, then check again."
            case "ineligible": message = "This account is not eligible for this reset."
            case "unavailable": message = "This reset is no longer available. Check Claude's Usage settings."
            default: throw ClaimError.uncertain
            }
            defaults.removeObject(forKey: storageKey)
            if defaults.synchronize() { unresolved = nil }
            AppLog.info(LogTag.plugin(providerID), "Explicit reset request completed: \(result)")
        } catch {
            if sent {
                message = "The result is unconfirmed. Check Claude's Usage settings, or retry this same request."
            } else {
                message = error is ClaimError ? error.localizedDescription : "Could not verify this reset. No reset request was sent."
            }
            AppLog.error(LogTag.plugin(providerID), "Reset request stopped: \(error.localizedDescription)")
        }
        // This hook only refreshes usage. It cannot redeem or retry anything.
        if sent { await refreshAfterClaim() }
        session = nil // Require a new read before the next independent use.
        if sent {
            do {
                let updated = try await fetchSession()
                session = updated
                status = updated.status
            } catch {
                message = (message ?? "") + " Refresh status to update the remaining resets."
                AppLog.error(LogTag.plugin(providerID), "Post-reset status refresh failed: \(error.localizedDescription)")
            }
        }
    }

    private func fetchSession() async throws -> Session {
        guard let auth = await credentials() else { throw ClaimError.accountChanged }
        let identity = try await client.fetchResetIdentity(accessToken: auth.accessToken, config: auth.config)
        let response = try await client.fetchUsage(accessToken: auth.accessToken, config: auth.config)
        guard let status = try ClaudeResetStatus.fromUsage(response) else { throw ClaudeUsageError.invalidResponse }
        guard await credentials() == auth else { throw ClaimError.accountChanged }
        return Session(credentials: auth, identity: identity, status: status, loadedAt: now())
    }

    private enum ClaimError: Error, LocalizedError {
        case accountChanged, grantChanged, storageFailed, uncertain
        var errorDescription: String? {
            switch self {
            case .accountChanged: "The account changed or needs a refresh. No reset request was sent."
            case .grantChanged: "This reset changed or is no longer usable. Check its status again."
            case .storageFailed: "Could not save the reset request safely. No reset request was sent."
            case .uncertain: "Claude did not confirm the reset result."
            }
        }
    }
}

private struct ClaudeResetClaimServiceKey: EnvironmentKey {
    static let defaultValue: ClaudeResetClaimService? = nil
}

extension EnvironmentValues {
    var claudeResetClaim: ClaudeResetClaimService? {
        get { self[ClaudeResetClaimServiceKey.self] }
        set { self[ClaudeResetClaimServiceKey.self] = newValue }
    }
}

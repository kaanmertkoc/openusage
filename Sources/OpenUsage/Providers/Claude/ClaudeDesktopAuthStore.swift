import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum ClaudeDesktopCredentialStatus: Sendable, Equatable {
    case notChecked
    case notFound
    case permissionRequired
    case stale
    case invalid
    case available
}

struct ClaudeDesktopCredentialResult: Sendable {
    var oauth: ClaudeOAuth?
    var status: ClaudeDesktopCredentialStatus
}

protocol ClaudeDesktopSafeStorageKeyReading: Sendable {
    func readPassword(allowInteraction: Bool) throws -> String?
}

struct ClaudeDesktopSafeStorageKeyReader: ClaudeDesktopSafeStorageKeyReading {
    private static let service = "Claude Safe Storage"
    private static let account = "Claude Key"

    func readPassword(allowInteraction: Bool) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8),
                  !password.isEmpty
            else {
                throw ClaudeDesktopCredentialError.invalidSafeStorageKey
            }
            return password
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw ClaudeDesktopCredentialError.permissionRequired
        default:
            throw ClaudeDesktopCredentialError.keychainFailure(Int(status))
        }
    }
}

enum ClaudeDesktopCredentialError: Error, Sendable {
    case permissionRequired
    case invalidSafeStorageKey
    case keychainFailure(Int)
    case invalidCiphertext
    case decryptionFailed(Int32)
}

/// Reads Claude Desktop's Electron OAuth cache as an externally owned, read-only credential source.
///
/// The refresh token is deliberately never decoded into `ClaudeOAuth`: Anthropic rotates refresh
/// tokens, so using one here would invalidate Claude Desktop's copy. OpenUsage only borrows a currently
/// valid access token and waits for Desktop to renew it.
struct ClaudeDesktopAuthStore: Sendable {
    private static let configRelativePath = "Library/Application Support/Claude/config.json"
    private static let cookieRelativePaths = [
        "Library/Application Support/Claude/Cookies",
        "Library/Application Support/Claude/Network/Cookies"
    ]
    private static let cacheV1Key = "oauth:tokenCache"
    private static let cacheV2Key = "oauth:tokenCacheV2"
    private static let apiHost = "https://api.anthropic.com"
    private static let usageScope = "user:profile"
    private static let expirySafetyMarginMs = 2 * 60 * 1000.0
    private static let cookieHosts = [".claude.ai", "claude.ai"]

    var files: TextFileAccessing
    var sqlite: SQLiteAccessing
    var keyReader: ClaudeDesktopSafeStorageKeyReading
    var homeDirectory: @Sendable () -> URL
    var now: @Sendable () -> Date
    private let keyCache: SafeStorageKeyCache

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keyReader: ClaudeDesktopSafeStorageKeyReading = ClaudeDesktopSafeStorageKeyReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        now: @escaping @Sendable () -> Date = Date.init,
        keyCache: SafeStorageKeyCache = SafeStorageKeyCache()
    ) {
        self.files = files
        self.sqlite = sqlite
        self.keyReader = keyReader
        self.homeDirectory = homeDirectory
        self.now = now
        self.keyCache = keyCache
    }

    /// Cheap, prompt-free evidence for first-run detection. The real refresh still decrypts and validates.
    func hasCredentialMaterial() -> Bool {
        let configPath = path(Self.configRelativePath)
        guard let text = try? files.readTextIfPresent(configPath),
              let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root[Self.cacheV2Key] is String || root[Self.cacheV1Key] is String
        else {
            return false
        }
        return Self.cookieRelativePaths.contains { files.exists(path($0)) }
    }

    func load(allowInteraction: Bool) -> ClaudeDesktopCredentialResult {
        guard hasCredentialMaterial() else {
            AppLog.info(LogTag.auth("claude"), "desktop load: no credential material (config/cookies missing)")
            return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
        }

        do {
            guard let key = try safeStorageKey(allowInteraction: allowInteraction) else {
                AppLog.info(LogTag.auth("claude"), "desktop load: Safe Storage key unavailable (interaction=\(allowInteraction))")
                return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
            }
            let accountUUID = loadLastKnownAccountUUID()
            guard let activeOrg = try loadActiveOrganization(key: key) else {
                AppLog.info(
                    LogTag.auth("claude"),
                    "desktop load: no lastActiveOrg cookie (account=\(Self.shortID(accountUUID)))"
                )
                return ClaudeDesktopCredentialResult(oauth: nil, status: .invalid)
            }
            guard let caches = try loadCaches(key: key) else {
                AppLog.info(
                    LogTag.auth("claude"),
                    "desktop load: token cache unreadable (org=\(Self.shortID(activeOrg)) account=\(Self.shortID(accountUUID)))"
                )
                return ClaudeDesktopCredentialResult(oauth: nil, status: .invalid)
            }

            let v2Orgs = Self.organizationIDs(in: caches.v2)
            let v1Orgs = Self.organizationIDs(in: caches.v1)
            AppLog.info(
                LogTag.auth("claude"),
                "desktop load: lastActiveOrg=\(Self.shortID(activeOrg)) account=\(Self.shortID(accountUUID)) v2Orgs=\(v2Orgs.map(Self.shortID).sorted()) v1Orgs=\(v1Orgs.map(Self.shortID).sorted())"
            )

            let selection = Self.selectCredential(
                activeOrganization: activeOrg,
                v2: caches.v2,
                v1: caches.v1,
                now: now()
            )
            switch selection {
            case .available(let oauth):
                AppLog.info(
                    LogTag.auth("claude"),
                    "desktop load: selected org=\(Self.shortID(activeOrg)) \(Self.oauthDebugSummary(oauth))"
                )
                return ClaudeDesktopCredentialResult(oauth: oauth, status: .available)
            case .stale:
                AppLog.info(LogTag.auth("claude"), "desktop load: only stale tokens for org=\(Self.shortID(activeOrg))")
                return ClaudeDesktopCredentialResult(oauth: nil, status: .stale)
            case .notFound:
                AppLog.info(LogTag.auth("claude"), "desktop load: no usable profile-scoped token for org=\(Self.shortID(activeOrg))")
                return ClaudeDesktopCredentialResult(oauth: nil, status: .notFound)
            case .invalid:
                AppLog.info(LogTag.auth("claude"), "desktop load: invalid cache entries for org=\(Self.shortID(activeOrg))")
                return ClaudeDesktopCredentialResult(oauth: nil, status: .invalid)
            }
        } catch ClaudeDesktopCredentialError.permissionRequired {
            AppLog.info(LogTag.auth("claude"), "desktop load: keychain permission required (manual refresh + Always Allow)")
            return ClaudeDesktopCredentialResult(oauth: nil, status: .permissionRequired)
        } catch {
            AppLog.error(LogTag.auth("claude"), "Claude Desktop credential read failed: \(error.localizedDescription)")
            return ClaudeDesktopCredentialResult(oauth: nil, status: .invalid)
        }
    }

    /// Account UUID Claude Desktop persists separately from the org cookie — who is logged in, not which org is active.
    private func loadLastKnownAccountUUID() -> String? {
        guard let text = try? files.readTextIfPresent(path(Self.configRelativePath)),
              let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["lastKnownAccountUuid"] as? String,
              UUID(uuidString: value) != nil
        else {
            return nil
        }
        return value.lowercased()
    }

    /// Log-safe short UUID (`aaaaaaaa…bbbbbbbb`) — never the full id in spammy lines, never tokens.
    private static func shortID(_ value: String?) -> String {
        guard let value, value.count >= 13 else { return value ?? "<none>" }
        return "\(value.prefix(8))…\(value.suffix(4))"
    }

    private static func oauthDebugSummary(_ oauth: ClaudeOAuth) -> String {
        let sub = oauth.subscriptionType ?? "<nil>"
        let tier = oauth.rateLimitTier ?? "<nil>"
        let scopes = (oauth.scopes ?? []).joined(separator: " ")
        let scopeLabel = scopes.isEmpty ? "<none>" : scopes
        return "sub=\(sub) tier=\(tier) scopes=[\(scopeLabel)]"
    }

    private static func organizationIDs(in cache: [String: Any]?) -> [String] {
        guard let cache else { return [] }
        var orgs = Set<String>()
        for key in cache.keys {
            if let parsed = parseCacheKey(key) {
                orgs.insert(parsed.organization)
            }
        }
        return Array(orgs)
    }

    private func safeStorageKey(allowInteraction: Bool) throws -> Data? {
        if let cached = keyCache.value { return cached }
        guard let password = try keyReader.readPassword(allowInteraction: allowInteraction) else {
            return nil
        }
        let key = try Self.deriveKey(password: password)
        keyCache.value = key
        return key
    }

    private func loadActiveOrganization(key: Data) throws -> String? {
        for relativePath in Self.cookieRelativePaths {
            let databasePath = path(relativePath)
            guard files.exists(databasePath) else { continue }
            for host in Self.cookieHosts {
                let hostSQL = host.replacingOccurrences(of: "'", with: "''")
                let sql = """
                SELECT CASE
                    WHEN length(value) > 0 THEN 'plain:' || hex(CAST(value AS BLOB))
                    ELSE 'encrypted:' || hex(encrypted_value)
                END
                FROM cookies
                WHERE name = 'lastActiveOrg' AND host_key = '\(hostSQL)'
                ORDER BY last_update_utc DESC
                LIMIT 1;
                """
                guard let encoded = try sqlite.queryValue(path: databasePath, sql: sql),
                      let separator = encoded.firstIndex(of: ":")
                else {
                    continue
                }
                let mode = String(encoded[..<separator])
                let hex = String(encoded[encoded.index(after: separator)...])
                guard let stored = Data(hexString: hex) else { continue }

                let value: Data
                if mode == "plain" {
                    value = stored
                } else if mode == "encrypted" {
                    let decrypted = try Self.decrypt(stored, key: key)
                    let hostHash = Data(SHA256.hash(data: Data(host.utf8)))
                    guard decrypted.starts(with: hostHash) else { continue }
                    value = decrypted.dropFirst(hostHash.count)
                } else {
                    continue
                }
                guard let organization = String(data: value, encoding: .utf8),
                      UUID(uuidString: organization) != nil
                else {
                    continue
                }
                return organization.lowercased()
            }
        }
        return nil
    }

    private func loadCaches(key: Data) throws -> (v2: [String: Any]?, v1: [String: Any]?)? {
        guard let text = try files.readTextIfPresent(path(Self.configRelativePath)),
              let data = text.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return (
            v2: try Self.decodeCache(root[Self.cacheV2Key], key: key),
            v1: try Self.decodeCache(root[Self.cacheV1Key], key: key)
        )
    }

    private static func decodeCache(_ stored: Any?, key: Data) throws -> [String: Any]? {
        guard let base64 = stored as? String else { return nil }
        guard let encrypted = Data(base64Encoded: base64) else {
            throw ClaudeDesktopCredentialError.invalidCiphertext
        }
        let plaintext = try decrypt(encrypted, key: key)
        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw ClaudeDesktopCredentialError.invalidCiphertext
        }
        return object
    }

    enum Selection: Sendable {
        case available(ClaudeOAuth)
        case stale
        case notFound
        case invalid
    }

    static func selectCredential(
        activeOrganization: String,
        v2: [String: Any]?,
        v1: [String: Any]?,
        now: Date
    ) -> Selection {
        let normalizedOrg = activeOrganization.lowercased()
        let v2Candidates = candidates(in: v2, organization: normalizedOrg, now: now)
        if !v2Candidates.available.isEmpty {
            AppLog.info(
                LogTag.auth("claude"),
                "desktop select: org=\(shortID(normalizedOrg)) cache=v2 candidates=[\(v2Candidates.available.map(\.debugLabel).joined(separator: "; "))]"
            )
        }
        if let best = v2Candidates.available.max(by: { $0.rank < $1.rank }) {
            AppLog.info(
                LogTag.auth("claude"),
                "desktop select: org=\(shortID(normalizedOrg)) winner=v2 \(best.debugLabel)"
            )
            return .available(best.oauth)
        }

        let v2Keys = Set(v2?.keys ?? Dictionary<String, Any>().keys)
        let v1Candidates = candidates(
            in: v1?.filter { !v2Keys.contains($0.key) },
            organization: normalizedOrg,
            now: now
        )
        if !v1Candidates.available.isEmpty {
            AppLog.info(
                LogTag.auth("claude"),
                "desktop select: org=\(shortID(normalizedOrg)) cache=v1 candidates=[\(v1Candidates.available.map(\.debugLabel).joined(separator: "; "))]"
            )
        }
        if let best = v1Candidates.available.max(by: { $0.rank < $1.rank }) {
            AppLog.info(
                LogTag.auth("claude"),
                "desktop select: org=\(shortID(normalizedOrg)) winner=v1 \(best.debugLabel)"
            )
            return .available(best.oauth)
        }
        if v2Candidates.sawStale || v1Candidates.sawStale { return .stale }
        if v2Candidates.sawInvalid || v1Candidates.sawInvalid { return .invalid }
        return .notFound
    }

    /// The OAuth client ID Claude's production login (Claude Code / Desktop) mints full-scope tokens
    /// under. Desktop's cache can hold several entries for one org — partial-scope leftovers from older
    /// logins included — and this client is how Desktop itself resolves the active login.
    private static let productionClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let inferenceScope = "user:inference"

    private struct Candidate {
        var oauth: ClaudeOAuth
        var clientID: String
        var scopes: [String]
        var expiresAt: Double

        /// Selection order mirrors Desktop's own resolution instead of raw expiry: production client
        /// with full scopes first, then any full-scope entry over bare `user:profile` leftovers, then
        /// scope richness, with expiry only as the final tiebreak. A stale wrong-tier token with a
        /// longer TTL must not outrank the current login.
        var rank: (Int, Int, Int, Double) {
            let hasFullScope = scopes.contains(ClaudeDesktopAuthStore.usageScope)
                && scopes.contains(ClaudeDesktopAuthStore.inferenceScope)
            let isProductionClient = clientID == ClaudeDesktopAuthStore.productionClientID
            return (
                isProductionClient && hasFullScope ? 1 : 0,
                hasFullScope ? 1 : 0,
                scopes.count,
                expiresAt
            )
        }

        /// Token-free label for selection logs (client prefix, scopes, stamped plan metadata, expiry).
        var debugLabel: String {
            let client = clientID.count >= 8 ? String(clientID.prefix(8)) : clientID
            let sub = oauth.subscriptionType ?? "<nil>"
            let tier = oauth.rateLimitTier ?? "<nil>"
            let scopeText = scopes.joined(separator: "+")
            let exp = expiresAt.isFinite
                ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: expiresAt / 1000))
                : "<nil>"
            return "client=\(client) scopes=\(scopeText) sub=\(sub) tier=\(tier) exp=\(exp)"
        }
    }

    private static func candidates(
        in cache: [String: Any]?,
        organization: String,
        now: Date
    ) -> (available: [Candidate], sawStale: Bool, sawInvalid: Bool) {
        guard let cache else { return ([], false, false) }
        var available: [Candidate] = []
        var sawStale = false
        var sawInvalid = false
        for (cacheKey, rawEntry) in cache {
            guard let parsedKey = parseCacheKey(cacheKey),
                  parsedKey.organization == organization,
                  parsedKey.apiHost == apiHost,
                  parsedKey.scopes.contains(usageScope)
            else {
                continue
            }
            guard !(rawEntry is NSNull) else { continue }
            guard let entry = rawEntry as? [String: Any],
                  let token = entry["token"] as? String,
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let expiresAt = number(entry["expiresAt"]),
                  expiresAt.isFinite
            else {
                sawInvalid = true
                continue
            }
            guard expiresAt > now.timeIntervalSince1970 * 1000 + expirySafetyMarginMs else {
                sawStale = true
                continue
            }
            let oauth = ClaudeOAuth(
                accessToken: token,
                refreshToken: nil,
                expiresAt: expiresAt,
                subscriptionType: entry["subscriptionType"] as? String,
                rateLimitTier: entry["rateLimitTier"] as? String,
                scopes: parsedKey.scopes
            )
            available.append(Candidate(
                oauth: oauth,
                clientID: parsedKey.clientID,
                scopes: parsedKey.scopes,
                expiresAt: expiresAt
            ))
        }
        return (available, sawStale, sawInvalid)
    }

    private struct CacheKey {
        var clientID: String
        var organization: String
        var apiHost: String
        var scopes: [String]
    }

    private static func parseCacheKey(_ value: String) -> CacheKey? {
        let marker = ":\(apiHost):"
        guard let markerRange = value.range(of: marker) else { return nil }
        let prefix = value[..<markerRange.lowerBound]
        guard let firstColon = prefix.firstIndex(of: ":") else { return nil }
        let clientID = String(prefix[..<firstColon])
        let organization = String(prefix[prefix.index(after: firstColon)...]).lowercased()
        guard UUID(uuidString: clientID) != nil, UUID(uuidString: organization) != nil else {
            return nil
        }
        let scopes = value[markerRange.upperBound...]
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return CacheKey(clientID: clientID, organization: organization, apiHost: apiHost, scopes: scopes)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    static func deriveKey(password: String) throws -> Data {
        let passwordData = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyCount = key.count
        let result = key.withUnsafeMutableBytes { keyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyCount
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw ClaudeDesktopCredentialError.invalidSafeStorageKey
        }
        return key
    }

    static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8),
              key.count == kCCKeySizeAES128
        else {
            throw ClaudeDesktopCredentialError.invalidCiphertext
        }

        let payload = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        var outputLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw ClaudeDesktopCredentialError.decryptionFailed(status)
        }
        output.count = outputLength
        return output
    }

    private func path(_ relativePath: String) -> String {
        homeDirectory().appendingPathComponent(relativePath).path
    }
}

final class SafeStorageKeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    var value: Data? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

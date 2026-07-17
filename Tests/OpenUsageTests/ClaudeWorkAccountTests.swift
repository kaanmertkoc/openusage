import Foundation
import Testing
@testable import OpenUsage

/// Personal-fork guarantees for the pinned two-account Claude setup (ClaudeAccounts.swift): the
/// Work tile must read ONLY the hashed keychain entry for its pinned config dir, and ambient
/// `CLAUDE_CONFIG_DIR` values must never leak into either tile.
struct ClaudeWorkAccountTests {
    private let workDir = "/Users/kaankoc/.claude-work"

    @Test func overriddenEnvironmentPinsAndUnsets() {
        let base = FakeEnvironment(["CLAUDE_CONFIG_DIR": "/ambient/dir", "OTHER": "kept"])
        let pinned = OverriddenEnvironmentReader(base: base, overrides: ["CLAUDE_CONFIG_DIR": workDir])
        #expect(pinned.value(for: "CLAUDE_CONFIG_DIR") == workDir)
        #expect(pinned.value(for: "OTHER") == "kept")

        let unset = OverriddenEnvironmentReader(base: base, overrides: ["CLAUDE_CONFIG_DIR": String?.none])
        #expect(unset.value(for: "CLAUDE_CONFIG_DIR") == nil)
        #expect(unset.value(for: "OTHER") == "kept")
    }

    @Test func workKeychainLookupIsHashedEntryOnly() {
        // sha256("/Users/kaankoc/.claude-work").prefix(8) — the suffix Claude Code itself derives
        // from CLAUDE_CONFIG_DIR, verified against `shasum -a 256`.
        let store = ClaudeAuthStore(
            environment: OverriddenEnvironmentReader(
                base: FakeEnvironment([:]),
                overrides: ["CLAUDE_CONFIG_DIR": workDir]
            ),
            allowsLegacyKeychainFallback: false
        )
        #expect(store.keychainServiceCandidates() == ["Claude Code-credentials-e6953223"])
    }

    @Test func defaultKeychainLookupKeepsLegacyFallback() {
        let store = ClaudeAuthStore(
            environment: OverriddenEnvironmentReader(
                base: FakeEnvironment([:]),
                overrides: ["CLAUDE_CONFIG_DIR": workDir]
            )
        )
        #expect(store.keychainServiceCandidates() == [
            "Claude Code-credentials-e6953223",
            "Claude Code-credentials"
        ])
    }

    @Test func personalAccountIgnoresAmbientConfigDir() {
        let store = ClaudeAuthStore(
            environment: OverriddenEnvironmentReader(
                base: FakeEnvironment(["CLAUDE_CONFIG_DIR": workDir]),
                overrides: ["CLAUDE_CONFIG_DIR": String?.none]
            )
        )
        #expect(store.keychainServiceCandidates() == ["Claude Code-credentials"])
    }

    @Test @MainActor func catalogRegistersBothClaudeAccounts() {
        let ids = ProviderCatalog.make().map(\.provider.id)
        #expect(ids.contains("claude"))
        #expect(ids.contains("claude-work"))
        let work = ProviderCatalog.make().first { $0.provider.id == "claude-work" }
        #expect(work?.provider.displayName == "Claude Work")
    }

    @Test @MainActor func workDescriptorIDsAreNamespaced() {
        let work = ClaudeProvider.workAccount()
        let ids = work.widgetDescriptors.map(\.id)
        #expect(ids.contains("claude-work.session"))
        #expect(ids.contains("claude-work.weekly"))
        #expect(!ids.contains { $0.hasPrefix("claude.") })
    }

    /// The cross-launch parse cache (#1017) replaces a whole identity's records with the file set the
    /// scan just saw, so two scanners sharing an identity but reading different files would evict each
    /// other every refresh — parsing everything from scratch forever instead of caching. The two pinned
    /// tiles must therefore never collide.
    @Test func pinnedAccountsUseSeparateParseCacheIdentities() async {
        let home = URL(fileURLWithPath: "/Users/kaankoc")
        let personal = ClaudeLogUsageScanner(
            environment: OverriddenEnvironmentReader(
                base: FakeEnvironment([:]), overrides: ["CLAUDE_CONFIG_DIR": String?.none]
            ),
            homeDirectory: { home }
        )
        let work = ClaudeLogUsageScanner(
            environment: OverriddenEnvironmentReader(
                base: FakeEnvironment([:]), overrides: ["CLAUDE_CONFIG_DIR": workDir]
            ),
            homeDirectory: { home },
            includeCoworkSandboxes: false
        )
        #expect(await personal.parseCacheIdentity() != work.parseCacheIdentity())
    }

    /// `includeCoworkSandboxes` changes which roots are scanned without changing any path the identity
    /// is otherwise derived from, so it has to be part of the key on its own. Turning it off must move
    /// the scanner to a different namespace even when everything else matches.
    @Test func coworkSandboxFlagSplitsTheParseCacheIdentity() async {
        let home = URL(fileURLWithPath: "/Users/kaankoc")
        let withSandboxes = ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home }
        )
        let withoutSandboxes = ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home }, includeCoworkSandboxes: false
        )
        #expect(await withSandboxes.parseCacheIdentity() != withoutSandboxes.parseCacheIdentity())
        // The default stays byte-identical to upstream's, so no existing cache is orphaned by the split.
        #expect(await !withSandboxes.parseCacheIdentity().contains("cowork="))
    }
}

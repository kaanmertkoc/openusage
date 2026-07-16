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
}

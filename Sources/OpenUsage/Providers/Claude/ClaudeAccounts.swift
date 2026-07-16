import Foundation

/// Personal-fork account pinning (see AGENTS.md "Personal fork"): two Claude tiles, each locked to
/// its own Claude Code config dir, so an ambient `CLAUDE_CONFIG_DIR` (a terminal launch, a work
/// shell profile) can never flip which account a tile shows.
extension ClaudeProvider {
    /// The default Claude tile, pinned to `~/.claude` — the personal account. `CLAUDE_CONFIG_DIR`
    /// is force-unset so both the credential lookup and the log scan resolve the default dir.
    @MainActor
    static func personalAccount() -> ClaudeProvider {
        let environment = OverriddenEnvironmentReader(overrides: ["CLAUDE_CONFIG_DIR": String?.none])
        return ClaudeProvider(
            authStore: ClaudeAuthStore(environment: environment),
            logUsageScanner: ClaudeLogUsageScanner(environment: environment)
        )
    }

    /// The work (Team) account tile, pinned to `~/.claude-work` (the dir the `cc2` shell alias
    /// points Claude Code at). Reads ONLY that dir's hashed keychain entry — never the legacy
    /// unhashed entry and never Claude Desktop, both of which hold the personal login and would
    /// silently mirror personal usage into this tile.
    @MainActor
    static func workAccount() -> ClaudeProvider {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-work").path
        let environment = OverriddenEnvironmentReader(overrides: ["CLAUDE_CONFIG_DIR": configDir])
        return ClaudeProvider(
            provider: Provider(
                id: "claude-work",
                displayName: "Claude Work",
                icon: .providerMark("claude"),
                links: [
                    .init(label: "Status", url: "https://status.anthropic.com/"),
                    .init(label: "Console", url: "https://console.anthropic.com/")
                ]
            ),
            authStore: ClaudeAuthStore(
                environment: environment,
                desktopFallbackEnabled: false,
                allowsLegacyKeychainFallback: false
            ),
            logUsageScanner: ClaudeLogUsageScanner(
                environment: environment,
                includeCoworkSandboxes: false
            )
        )
    }
}

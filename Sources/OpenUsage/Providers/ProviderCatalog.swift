import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    static func make(defaults: UserDefaults = .standard) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name.
        let claudeServers: [ProviderRuntime] = RemoteClaudeServer.configured.map { ClaudeServerProvider(server: $0) }
        return [
            // Personal fork: both Claude accounts as pinned instances (see ClaudeAccounts.swift),
            // plus configured Claude servers and the existing server1 Codex/OpenCode tiles.
            ClaudeProvider.personalAccount(),
            ClaudeProvider.workAccount()
        ] + claudeServers + [
            CodexProvider(),
            CodexServerProvider(),
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(defaults: defaults),
            DevinProvider(),
            GrokProvider(),
            OpenCodeProvider(),
            OpenCodeServerProvider(),
            OpenRouterProvider(),
            ZAIProvider()
        ]
    }
}

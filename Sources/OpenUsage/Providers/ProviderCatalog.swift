import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    static func make(defaults: UserDefaults = .standard) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name.
        [
            // Personal fork: both Claude accounts as pinned instances (see ClaudeAccounts.swift),
            // plus the server1 remote tiles right after their local counterparts (RemoteServer/).
            ClaudeProvider.personalAccount(),
            ClaudeProvider.workAccount(),
            ClaudeServerProvider(),
            CodexProvider(),
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

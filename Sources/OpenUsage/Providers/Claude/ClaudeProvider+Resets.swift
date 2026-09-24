import Foundation

extension ClaudeProvider {
    struct ResetAuthorization {
        let credentials: ClaudeResetCredentials
        let generation: ClaudeCredentialGeneration
        let desktop: Bool
    }

    /// Use only the credential that actually produced this card's latest successful live usage.
    /// Work's auth store keeps Desktop/legacy fallback disabled; no new credential selection path.
    func credentialsForReset() async -> ClaudeResetCredentials? {
        guard let authorization = resetAuthorization else { return nil }
        let generation = await loadOffMainActor { [authStore] in
            authStore.credentialGeneration(forceDesktopFallback: authorization.desktop)
        }
        guard generation == authorization.generation,
              resetAuthorization?.credentials == authorization.credentials else { return nil }
        return authorization.credentials
    }
}

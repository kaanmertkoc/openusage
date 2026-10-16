import Foundation

/// The sync job reads the same JSON source as the app. IDs own saved layout/cache identities;
/// changing a display name must not change the ID.
struct RemoteClaudeServer: Decodable, Sendable {
    let id: String
    let name: String
    let sshTarget: String?
    let claudeProjectsPath: String?
    let sshIdentityFile: String?
    let setupRequired: String?

    init(id: String, name: String, sshTarget: String? = nil, claudeProjectsPath: String? = nil,
         setupRequired: String? = nil, sshIdentityFile: String? = nil) {
        self.id = id
        self.name = name
        self.sshTarget = sshTarget
        self.claudeProjectsPath = claudeProjectsPath
        self.sshIdentityFile = sshIdentityFile
        self.setupRequired = setupRequired
    }

    var providerID: String { "claude-\(id)" }
    var syncRoot: URL { RemoteServerSync.defaultRoot(hostLabel: id) }

    static let configured: [RemoteClaudeServer] = {
        do {
            guard let url = Bundle.openUsageResources.url(forResource: "remote_servers", withExtension: "json") else {
                throw ConfigurationError.invalid("Missing bundled remote_servers.json")
            }
            return try decode(Data(contentsOf: url))
        } catch {
            // Required build resource: a broken bundle must not silently drop a server.
            AppLog.error(.config, "Remote server configuration: \(error.localizedDescription)")
            fatalError("Invalid bundled remote server configuration: \(error.localizedDescription)")
        }
    }()

    static func decode(_ data: Data) throws -> [RemoteClaudeServer] {
        let servers = try JSONDecoder().decode([RemoteClaudeServer].self, from: data)
        var ids: Set<String> = []
        for server in servers {
            guard server.id.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil,
                  ids.insert(server.id).inserted,
                  !server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ConfigurationError.invalid("Invalid or duplicate remote server: \(server.id)") }
            if let message = server.setupRequired {
                guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      server.sshTarget == nil, server.claudeProjectsPath == nil, server.sshIdentityFile == nil
                else { throw ConfigurationError.invalid("Invalid pending server setup: \(server.id)") }
            } else {
                guard let target = server.sshTarget, let path = server.claudeProjectsPath,
                      target.range(of: #"^[a-zA-Z0-9_-]+@[a-zA-Z0-9][a-zA-Z0-9.-]*$"#, options: .regularExpression) != nil,
                      path.hasPrefix("/"), !path.contains("\n"), !path.contains("\0")
                else { throw ConfigurationError.invalid("Invalid remote server connection: \(server.id)") }
            }
            if let identity = server.sshIdentityFile {
                guard (identity.hasPrefix("/") || identity.hasPrefix("~/")),
                      !identity.contains("\n"), !identity.contains("\0")
                else { throw ConfigurationError.invalid("Invalid SSH identity path: \(server.id)") }
            }
        }
        guard servers.contains(where: { $0.id == "server1" }) else {
            throw ConfigurationError.invalid("Keep server1's ID to preserve its existing history and layout")
        }
        return servers
    }

    private enum ConfigurationError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): message }
        }
    }
}

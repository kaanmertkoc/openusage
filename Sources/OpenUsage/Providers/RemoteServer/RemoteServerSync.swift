import Foundation

/// Shared plumbing for the server1 remote tiles: the rsync destination layout
/// (`~/.openusage-remote/server1/`, populated by `scripts/remote-sync.sh` on a 5-minute launchd
/// schedule over Tailscale SSH) and the sync-freshness contract both server providers surface.
enum RemoteServerSync {
    static let hostLabel = "server1"
    /// Sync considered stale after this long without a successful run (the launchd job runs every 5 min).
    static let staleThreshold: TimeInterval = 15 * 60

    static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openusage-remote/\(hostLabel)")
    }

    /// The timestamp `scripts/remote-sync.sh` writes after a fully successful sync of this host.
    /// `nil` when the marker is missing or unparsable — the sync has never completed.
    static func lastSyncDate(root: URL) -> Date? {
        let marker = root.appendingPathComponent(".last-sync")
        guard let raw = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        return OpenUsageISO8601.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Header warning (amber triangle) when the last sync is older than the threshold. The tiles keep
    /// showing the last-synced numbers — stale data with a warning beats a blank card.
    static func staleWarning(lastSync: Date, now: Date) -> String? {
        let age = now.timeIntervalSince(lastSync)
        guard age > staleThreshold else { return nil }
        return "Server sync is stale (last synced \(ageLabel(age)) ago). Check scripts/remote-sync.sh and Tailscale."
    }

    private static func ageLabel(_ age: TimeInterval) -> String {
        let minutes = Int((age / 60).rounded())
        if minutes < 120 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

enum RemoteServerSyncError: Error, LocalizedError {
    case notSynced

    var errorDescription: String? {
        "No synced data from \(RemoteServerSync.hostLabel) yet. Run scripts/remote-sync.sh (or load its launchd job) first."
    }
}

import AppKit

/// Rejects a second copy of OpenUsage at launch (issue #635). macOS can fire two independent launch
/// triggers on reboot — session restoration ("Reopen windows when logging back in") and the
/// `SMAppService` login item — and a crashed or hung copy can linger holding `127.0.0.1:6736`.
/// Without a guard either path yields a duplicate menu-bar icon (or, for an `LSUIElement` app, a
/// launch that "does nothing"). The decision is split out from the live-workspace query so it can be
/// unit-tested without a second running process.
@MainActor
enum SingleInstanceGuard {
    /// Pure decision: the PID of the instance we should yield to, or `nil` if we should keep running.
    ///
    /// Tie-break is deterministic — the lowest-PID instance is the survivor; every other copy yields
    /// to it. This matters for the reboot race the guard targets: when two launches register at once,
    /// a naive "yield if any other instance exists" rule makes *both* yield and terminate, leaving
    /// zero running instances. Lowest-PID-wins guarantees exactly one survivor. (The one theoretical
    /// hole — PID wraparound between an older instance's launch and ours — needs ~99k intervening PIDs
    /// and is negligible.)
    static func instanceToYieldTo(myPID: pid_t, runningPIDs: [pid_t]) -> pid_t? {
        guard let lowestPeer = runningPIDs.filter({ $0 != myPID }).min(), lowestPeer < myPID else {
            return nil
        }
        return lowestPeer
    }

    /// Live check + handoff. When another instance owns the slot, hands focus to the surviving copy
    /// and returns `true` so the caller bows out before grabbing the local-API port or adding a status
    /// item. Returns `false` (no-op) when we are the survivor, or when unbundled (`swift run`/preview)
    /// has no bundle identifier to match against.
    static func deferToExistingInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let survivorPID = instanceToYieldTo(
            myPID: me.processIdentifier,
            runningPIDs: running.map(\.processIdentifier)
        ) else {
            return false
        }
        // Resolved from the same snapshot the decision used, so the survivor is still present.
        running.first { $0.processIdentifier == survivorPID }?.activate()
        return true
    }
}

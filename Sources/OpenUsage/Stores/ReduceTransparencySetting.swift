import Foundation

/// Switch that drops the popover's Liquid Glass for a solid, higher-contrast surface — the fix for
/// "I can't read it over a busy desktop". It's *on* by default for readability; users who prefer
/// glass can turn it off in Settings. Stored as a plain `Bool` under one `UserDefaults.standard`
/// key, so it doesn't need the `UserDefaultsBacked` enum machinery; this namespace just holds the
/// key and a live reader.
///
/// The app toggle is OR'd with macOS's own *Reduce Transparency* accessibility setting at the view
/// layer (`DashboardView`), so a user who has the system setting on gets the solid surface even if
/// they never touch this toggle.
enum ReduceTransparencySetting {
    /// The `UserDefaults.standard` key this setting persists under.
    static let key = "reduceTransparency"

    /// Posted when the in-app toggle flips, so the panel's AppKit glass backdrop
    /// (`StatusItemController`) can swap to a solid surface live — `@AppStorage` reactivity only
    /// re-renders the in-window content, not the window's own backdrop. Mirrors
    /// `AppearanceSetting.didChangeNotification`. (macOS's *own* Reduce Transparency setting is
    /// observed separately, via `NSWorkspace`.)
    static let didChangeNotification = Notification.Name("ReduceTransparencySettingDidChange")

    /// The stored choice, read live from `UserDefaults.standard`. Defaults to `true` when unset
    /// (fresh installs and existing users who never touched the toggle get the solid surface); an
    /// explicit choice is preserved because the key then reads back as a non-nil object. The
    /// `@AppStorage` sites that mirror this key default to `true` for the same reason.
    static var current: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

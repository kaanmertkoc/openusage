import AppKit

/// Presents the standard macOS About panel for the footer menu's "About OpenUsage" item.
///
/// As a menu-bar accessory app, OpenUsage is not the active app while the popover is showing, so the
/// app is activated first — otherwise the panel would open behind whatever app currently owns the
/// foreground. The panel pulls the app icon, name, and version (`CFBundleShortVersionString` — the
/// same string `AppInfo.version` surfaces in the footer) straight from the bundle; we only supply the
/// credits line, naming the maintainers and linking the GitHub repo.
enum AboutPanel {
    @MainActor
    static func present() {
        NSApp.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// Personal build: plain credits, no author/support links (fork doctrine — see AGENTS.md).
    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        return NSAttributedString(
            string: "Personal local build.\nTelemetry, upstream updates, and support links are disabled.",
            attributes: base
        )
    }
}

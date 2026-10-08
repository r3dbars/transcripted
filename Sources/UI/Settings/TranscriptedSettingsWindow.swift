import AppKit

/// The Settings window's configuration, separate from the app-state graph its
/// controller builds, so a test can make the real window.
@MainActor
enum TranscriptedSettingsWindow {
    static func make(contentViewController: NSViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcripted Settings"
        window.titleVisibility = .hidden
        // Two-tone split runs edge-to-edge; the traffic lights float over the
        // sidebar tone (Things-style) instead of sitting in a toolbar band.
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar tells AppKit to use the taller titlebar
        // metrics, which insets the traffic lights from the top edge instead
        // of pinning them against it. The toolbar itself never shows items.
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.contentViewController = contentViewController
        window.contentMinSize = NSSize(width: 880, height: 640)
        window.isReleasedWhenClosed = false
        // This is a normal user-facing app window. Keep it available to the
        // standard macOS window screenshot and screen-sharing tools.
        window.sharingType = .readOnly
        return window
    }
}

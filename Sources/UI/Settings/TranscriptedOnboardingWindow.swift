import AppKit

/// The onboarding window's configuration, independent of its permission views.
@MainActor
enum TranscriptedOnboardingWindow {
    static func make(preferredSize: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: preferredSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Transcripted"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Window tabbing pulls in AppKit's Sidecar "Move to iPad" menu items
        // (Sentry APPLE-MACOS-3K). Setup is a single non-document window.
        window.tabbingMode = .disallowed
        // Fixed size: the content is laid out for one frame, so resizing only
        // added empty margin.
        window.minSize = preferredSize
        // First-run setup should be capturable for support and QA walkthroughs.
        window.sharingType = .readOnly
        return window
    }
}

import AppKit

/// Launch-time window choices that keep AppKit from hanging the main thread
/// on Sidecar XPC (Sentry APPLE-MACOS-3K).
///
/// Creating an `NSWindow` (including the Notch island `NSPanel`) or letting
/// AppKit build Window-menu tab / "Move to iPad" items instantiates
/// `_NSWindowSidecarDeviceCache`. That cache observes Sidecar device-generation
/// notifications and answers them with a synchronous XPC call on the main
/// thread. A 5+ second wait there is an app hang.
enum AppLaunchWindowPolicy {
    /// The island panel is created on first show. `prewarm()` orderFronts an
    /// NSPanel, which is enough to register the Sidecar cache for the rest of
    /// the process — including idle login-item launches with no visible window.
    static let prewarmsIslandPanel = false

    /// Call from `TranscriptedApp.init`, before any window exists. Automatic
    /// window tabbing is how AppKit first fills the Window menu's Sidecar items.
    static func disableAutomaticWindowTabbing() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
}

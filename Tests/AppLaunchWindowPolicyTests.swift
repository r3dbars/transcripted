import AppKit
import Foundation

/// Launch must not build an NSWindow that registers AppKit's Sidecar device
/// cache, and it must turn off window tabbing before any window exists. That
/// cache answers Sidecar device-generation notifications with a synchronous
/// XPC call on the main thread (Sentry APPLE-MACOS-3K).
func testAppLaunchWindowPolicy() {
    runSuite("Launch does not prewarm the island panel") {
        assertFalse(
            AppLaunchWindowPolicy.prewarmsIslandPanel,
            "an NSPanel at launch registers AppKit's Sidecar device cache, which then hangs the main thread on Sidecar XPC"
        )
    }

    runSuite("Launch turns off automatic window tabbing before any window exists") {
        _ = NSApplication.shared
        NSWindow.allowsAutomaticWindowTabbing = true
        AppLaunchWindowPolicy.disableAutomaticWindowTabbing()
        assertFalse(
            NSWindow.allowsAutomaticWindowTabbing,
            "window tabbing is how AppKit first builds the Window menu's Sidecar items"
        )
    }
}

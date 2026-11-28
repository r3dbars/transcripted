import Foundation

/// Launch must not build an NSWindow that registers AppKit's Sidecar device
/// cache. That cache answers Sidecar device-generation notifications with a
/// synchronous XPC call on the main thread (Sentry APPLE-MACOS-3K).
///
/// Do not mutate `NSWindow.allowsAutomaticWindowTabbing` here. Fast tests
/// already run inside `NSApplication.run()`, and flipping that class property
/// is one of the AppKit paths that instantiates `_NSWindowSidecarDeviceCache`.
/// Window-level `tabbingMode = .disallowed` is pinned in OverlayScreenSharePrivacyTests.
@MainActor
func testAppLaunchWindowPolicy() async {
    runSuite("Launch does not prewarm the island panel") {
        assertFalse(
            AppLaunchWindowPolicy.prewarmsIslandPanel,
            "an NSPanel at launch registers AppKit's Sidecar device cache, which then hangs the main thread on Sidecar XPC"
        )
    }
}

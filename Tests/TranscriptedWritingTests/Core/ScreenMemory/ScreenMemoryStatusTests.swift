import Testing
@testable import TranscriptedWritingCore

/// 2026-08-16 owner directive: Screen Recording permission is required for
/// Tilde to suggest at all. These tests are the "both directions" coverage
/// the directive asked for — permission granted vs. revoked, toggle on vs.
/// off — expressed as a pure decision so it needs no real TCC state, no
/// live socket, and no AppKit menu to prove.
@Suite("Screen Memory status")
struct ScreenMemoryStatusTests {
    @Test("Enabled and permitted, nothing else in the way: suggestions flow")
    func enabledAndPermittedAllowsSuggestions() {
        let status = ScreenMemoryStatus.evaluate(enabled: true, permissionGranted: true)
        #expect(status == .on)
        #expect(status.allowsSuggestions)
    }

    @Test("Permission revoked while running: suggestions stop, even with the toggle on")
    func permissionRevokedBlocksSuggestions() {
        let status = ScreenMemoryStatus.evaluate(enabled: true, permissionGranted: false)
        #expect(status == .noPermission)
        #expect(!status.allowsSuggestions)
    }

    @Test("Permission granted again while running: suggestions resume, no restart needed")
    func permissionRegrantedRestoresSuggestions() {
        // The same call, over time, as the OS decision changes underneath —
        // nothing here is cached, so re-evaluating is exactly how a live
        // gate recovers on the very next request.
        #expect(!ScreenMemoryStatus.evaluate(enabled: true, permissionGranted: false).allowsSuggestions)
        #expect(ScreenMemoryStatus.evaluate(enabled: true, permissionGranted: true).allowsSuggestions)
    }

    @Test("Toggle off is checked before permission, and reads as the user's own choice")
    func disabledTogglePrecedesPermissionCheck() {
        // Enabled=false with permissionGranted=true must still read
        // `.disabled`, not `.on` — the user's own choice is a distinct,
        // plainly-labeled reason from a missing OS permission.
        let status = ScreenMemoryStatus.evaluate(enabled: false, permissionGranted: true)
        #expect(status == .disabled)
        #expect(!status.allowsSuggestions)
    }

    @Test("Turning the toggle back on restores suggestions immediately, permission already granted")
    func togglingBackOnRestoresSuggestions() {
        #expect(!ScreenMemoryStatus.evaluate(enabled: false, permissionGranted: true).allowsSuggestions)
        #expect(ScreenMemoryStatus.evaluate(enabled: true, permissionGranted: true).allowsSuggestions)
    }

    @Test("Screen lock pauses capture but never blocks suggestions")
    func screenLockDoesNotBlockSuggestions() {
        let status = ScreenMemoryStatus.evaluate(
            enabled: true,
            permissionGranted: true,
            screenLocked: true,
            secureInputActive: false
        )
        #expect(status == .capturePausedScreenLocked)
        #expect(status.allowsSuggestions)
    }

    @Test("Secure input pauses capture but never blocks suggestions here (the IME suspends itself independently)")
    func secureInputDoesNotBlockSuggestionsAtThisLayer() {
        let status = ScreenMemoryStatus.evaluate(
            enabled: true,
            permissionGranted: true,
            screenLocked: false,
            secureInputActive: true
        )
        #expect(status == .capturePausedSecureInput)
        #expect(status.allowsSuggestions)
    }

    @Test("Screen lock is checked before secure input when both are true")
    func screenLockTakesPriorityOverSecureInput() {
        let status = ScreenMemoryStatus.evaluate(
            enabled: true,
            permissionGranted: true,
            screenLocked: true,
            secureInputActive: true
        )
        #expect(status == .capturePausedScreenLocked)
    }

    @Test("Disabled and no-permission are distinguishable, unlike a single collapsed off state")
    func disabledAndNoPermissionAreDistinct() {
        #expect(ScreenMemoryStatus.evaluate(enabled: false, permissionGranted: false) == .disabled)
        #expect(ScreenMemoryStatus.evaluate(enabled: true, permissionGranted: false) == .noPermission)
    }

    @Test("screenLocked/secureInputActive default to false when omitted")
    func lockAndSecureInputDefaultFalse() {
        #expect(ScreenMemoryStatus.evaluate(enabled: true, permissionGranted: true) == .on)
    }
}

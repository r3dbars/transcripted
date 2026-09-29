import Testing
@testable import TranscriptedWritingCore

/// Promise: Screen Memory reads only the window the user is typing in.
/// Given the typing target and what's on screen, the policy either names
/// that one window or refuses. Other visible apps are never a capture
/// target, and anything it can't prove about the focused window means
/// nothing is captured.
@Suite("Focused window capture policy")
struct FocusedWindowCapturePolicyTests {
    private typealias Policy = FocusedWindowCapturePolicy

    private let slack = "com.tinyspeck.slackmacgap"
    private let safari = "com.apple.Safari"
    private let slackPID: Int32 = 400
    private let safariPID: Int32 = 500
    private let slackWindow: UInt32 = 41
    private let safariWindow: UInt32 = 51

    private func target(
        bundle: String? = "com.tinyspeck.slackmacgap",
        pid: Int32? = 400,
        window: UInt32? = 41
    ) -> TypingTargetIdentity {
        TypingTargetIdentity(
            bundleIdentifier: bundle,
            processIdentifier: pid,
            windowIdentifier: window,
            fieldSessionIdentifier: "field-1",
            generation: 1
        )
    }

    /// Slack's chat window in front, Safari visible behind it.
    private var desktop: [Policy.Window] {
        [
            Policy.Window(windowIdentifier: slackWindow, processIdentifier: slackPID,
                          bundleIdentifier: slack, layer: 0, zOrderRank: 0),
            Policy.Window(windowIdentifier: safariWindow, processIdentifier: safariPID,
                          bundleIdentifier: safari, layer: 0, zOrderRank: 1),
        ]
    }

    private func choose(
        target: TypingTargetIdentity?,
        windows: [Policy.Window]? = nil,
        frontmostPID: Int32? = 400,
        keyboardFocusPID: Int32? = nil,
        excludedApps: Set<String> = [],
        inScope: @escaping (String) -> Bool = { _ in true }
    ) -> Policy.Choice {
        Policy.choose(
            target: target,
            windows: windows ?? desktop,
            focus: Policy.FocusEvidence(
                frontmostApplicationProcessIdentifier: frontmostPID,
                keyboardFocusProcessIdentifier: keyboardFocusPID
            ),
            excludedApps: excludedApps,
            appInScope: inScope
        )
    }

    @Test("The focused window of the app being typed in, in scope, is the only capture target")
    func focusedWindowInScope() {
        #expect(choose(target: target()) == .capture(windowIdentifier: slackWindow))
        // Accessibility agreeing on the focused process changes nothing.
        #expect(choose(target: target(), keyboardFocusPID: slackPID) == .capture(windowIdentifier: slackWindow))
    }

    @Test("Other visible apps are never captured, even in front of the typing app")
    func otherAppsVisible() {
        // Safari is frontmost on screen, but the user is typing in Slack:
        // the target is still Slack's window, never Safari's.
        var windows = desktop
        windows[0] = Policy.Window(windowIdentifier: slackWindow, processIdentifier: slackPID,
                                   bundleIdentifier: slack, layer: 0, zOrderRank: 1)
        windows[1] = Policy.Window(windowIdentifier: safariWindow, processIdentifier: safariPID,
                                   bundleIdentifier: safari, layer: 0, zOrderRank: 0)
        #expect(choose(target: target(), windows: windows) == .capture(windowIdentifier: slackWindow))

        // A typing target that points at another app's window while a
        // different app is frontmost is refused, not captured.
        #expect(choose(target: target(bundle: safari, pid: safariPID, window: safariWindow))
            == .refuse(.notFrontmostApp))
    }

    @Test("Keyboard focus in a different app refuses the capture")
    func keyboardFocusElsewhere() {
        // A launcher panel has keyboard focus while Slack stays frontmost.
        #expect(choose(target: target(), keyboardFocusPID: 999) == .refuse(.keyboardFocusElsewhere))
    }

    @Test("A window behind another window of the same app is not the focused window")
    func sameAppBackWindow() {
        let windows = desktop + [
            Policy.Window(windowIdentifier: 42, processIdentifier: slackPID,
                          bundleIdentifier: slack, layer: 0, zOrderRank: 2),
        ]
        #expect(choose(target: target(window: 42), windows: windows) == .refuse(.notFocusedWindow))
        #expect(choose(target: target(), windows: windows) == .capture(windowIdentifier: slackWindow))
    }

    @Test("An excluded focused window is never captured")
    func focusedWindowExcluded() {
        #expect(choose(target: target(), excludedApps: [slack]) == .refuse(.excluded(bundleIdentifier: slack)))
        // Exclusion matching ignores case, same as everywhere else.
        #expect(choose(target: target(), excludedApps: ["COM.TINYSPECK.SLACKMACGAP"])
            == .refuse(.excluded(bundleIdentifier: slack)))
    }

    @Test("Password managers are excluded with an empty exclusion list")
    func passwordManagerAlwaysExcluded() {
        let onePassword = "com.1password.1password"
        let windows = [
            Policy.Window(windowIdentifier: 7, processIdentifier: 700,
                          bundleIdentifier: onePassword, layer: 0, zOrderRank: 0),
        ]
        #expect(choose(target: target(bundle: onePassword, pid: 700, window: 7), windows: windows, frontmostPID: 700)
            == .refuse(.excluded(bundleIdentifier: onePassword)))
    }

    @Test("A focused window outside the Writing app scope is never captured")
    func focusedWindowOutOfScope() {
        #expect(choose(target: target(), inScope: { $0 != "com.tinyspeck.slackmacgap" })
            == .refuse(.outOfScope(bundleIdentifier: slack)))
    }

    @Test("No identifiable focused window captures nothing")
    func noIdentifiableWindow() {
        // No typing target at all.
        #expect(choose(target: nil) == .refuse(.noTarget))
        // A target missing its window or process.
        #expect(choose(target: target(window: nil)) == .refuse(.noTarget))
        #expect(choose(target: target(pid: nil)) == .refuse(.noTarget))
        // The target window isn't on screen any more.
        #expect(choose(target: target(window: 99)) == .refuse(.windowNotVisible))
        // The frontmost app is unknown.
        #expect(choose(target: target(), frontmostPID: nil) == .refuse(.notFrontmostApp))
        // The window has no z-order rank, so it can't be proven to be in front.
        let unranked = [
            Policy.Window(windowIdentifier: slackWindow, processIdentifier: slackPID,
                          bundleIdentifier: slack, layer: 0, zOrderRank: nil),
        ]
        #expect(choose(target: target(), windows: unranked) == .refuse(.notFocusedWindow))
        // The window's app reports no bundle ID, so exclusions and scope
        // can't be checked.
        let anonymous = [
            Policy.Window(windowIdentifier: slackWindow, processIdentifier: slackPID,
                          bundleIdentifier: nil, layer: 0, zOrderRank: 0),
        ]
        #expect(choose(target: target(bundle: nil), windows: anonymous) == .refuse(.unknownApp))
    }

    @Test("A window owned by another process or app than the typing target is refused")
    func ownerMismatch() {
        // Window IDs are reused; the ID alone doesn't prove ownership.
        #expect(choose(target: target(pid: 401)) == .refuse(.ownerMismatch))
        #expect(choose(target: target(bundle: "com.example.other")) == .refuse(.ownerMismatch))
    }

    @Test("Panels, menus and overlays above the normal window layer are never capture targets")
    func nonNormalLayer() {
        let overlay = [
            Policy.Window(windowIdentifier: slackWindow, processIdentifier: slackPID,
                          bundleIdentifier: slack, layer: 25, zOrderRank: 0),
        ]
        #expect(choose(target: target(), windows: overlay) == .refuse(.notNormalWindow))
    }
}

import Foundation
import Testing
@testable import TranscriptedWritingCore

@Suite("Capture trigger policy")
struct CaptureTriggerPolicyTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func decide(
        trigger: CaptureTriggerPolicy.Trigger = .windowChanged,
        enabled: Bool = true,
        screenLocked: Bool = false,
        secureInputActive: Bool = false,
        textFieldActive: Bool = true,
        completionSessionActive: Bool = true,
        visibleWindowOwnerBundleIdentifiers: [String] = ["com.apple.TextEdit"],
        excludedApps: Set<String> = [],
        lastCaptureAt: Date? = nil,
        now: Date? = nil
    ) -> CaptureTriggerPolicy.Decision {
        CaptureTriggerPolicy.decision(
            for: trigger,
            enabled: enabled,
            screenLocked: screenLocked,
            secureInputActive: secureInputActive,
            textFieldActive: textFieldActive,
            completionSessionActive: completionSessionActive,
            visibleWindowOwnerBundleIdentifiers: visibleWindowOwnerBundleIdentifiers,
            excludedApps: excludedApps,
            lastCaptureAt: lastCaptureAt,
            now: now ?? epoch
        )
    }

    @Test("Off by default: the master toggle blocks before anything else is checked")
    func disabledBlocksFirst() {
        // Every other gate is wide open; only `enabled` says no.
        #expect(decide(
            enabled: false,
            secureInputActive: true,
            excludedApps: ["com.apple.TextEdit"]
        ) == .skip(.disabled))
    }

    @Test("Screen lock blocks capture")
    func screenLockedBlocks() {
        #expect(decide(screenLocked: true) == .skip(.screenLocked))
    }

    @Test("Secure Event Input blocks capture unconditionally")
    func secureInputBlocks() {
        #expect(decide(secureInputActive: true) == .skip(.secureInput))
    }

    @Test("No active text field blocks every capture trigger")
    func textFieldRequired() {
        #expect(decide(textFieldActive: false) == .skip(.noActiveTextField))
        #expect(decide(
            trigger: .typingPause(elapsedSeconds: 30),
            textFieldActive: false
        ) == .skip(.noActiveTextField))
    }

    @Test("Window-change fires without requiring an active completion session")
    func windowChangeIgnoresSessionState() {
        #expect(decide(trigger: .windowChanged, completionSessionActive: false) == .capture)
    }

    @Test("Text-field focus fires without requiring an existing completion session")
    func textFieldFocusStartsSession() {
        #expect(decide(trigger: .textFieldFocused, completionSessionActive: false) == .capture)
    }

    @Test("Typing pause with no active completion session is not a trigger")
    func typingPauseRequiresActiveSession() {
        #expect(decide(
            trigger: .typingPause(elapsedSeconds: 5),
            completionSessionActive: false
        ) == .skip(.noActiveCompletionSession))
    }

    @Test("Typing pause below the 250ms threshold does not fire")
    func typingPauseBelowThreshold() {
        #expect(decide(
            trigger: .typingPause(elapsedSeconds: 0.249),
            completionSessionActive: true
        ) == .skip(.belowTypingPauseThreshold))
    }

    @Test("Typing pause exactly at and above the threshold fires")
    func typingPauseAtOrAboveThreshold() {
        #expect(decide(
            trigger: .typingPause(elapsedSeconds: 0.25),
            completionSessionActive: true
        ) == .capture)
        #expect(decide(
            trigger: .typingPause(elapsedSeconds: 30),
            completionSessionActive: true
        ) == .capture)
    }

    @Test("A non-frontmost excluded window still blocks capture — capture is full-display")
    func nonFrontmostExclusionBlocks() {
        // Signal sits behind the frontmost editor; frontmost is not excluded,
        // but Signal is, and it is still on screen.
        #expect(decide(
            visibleWindowOwnerBundleIdentifiers: ["com.apple.TextEdit", "org.whispersystems.signal-desktop"],
            excludedApps: ["org.whispersystems.signal-desktop"]
        ) == .skip(.excludedWindow(appBundleIdentifier: "org.whispersystems.signal-desktop")))
    }

    @Test("Frontmost window excluded blocks capture too")
    func frontmostExclusionBlocks() {
        #expect(decide(
            visibleWindowOwnerBundleIdentifiers: ["com.1password.1password"],
            excludedApps: ["com.1password.1password"]
        ) == .skip(.excludedWindow(appBundleIdentifier: "com.1password.1password")))
    }

    @Test("No visible window is on the exclusion list: capture proceeds")
    func noExclusionMatchAllows() {
        #expect(decide(
            visibleWindowOwnerBundleIdentifiers: ["com.apple.TextEdit", "com.apple.Safari"],
            excludedApps: ["org.whispersystems.signal-desktop"]
        ) == .capture)
    }

    @Test("First-ever capture (no lastCaptureAt) is never blocked by cadence")
    func firstCaptureIgnoresCadence() {
        #expect(decide(lastCaptureAt: nil) == .capture)
    }

    @Test("A typing-pause capture within the cadence cap is blocked, with remaining time reported")
    func cadenceCapBlocksWithinWindow() {
        let last = epoch
        let elapsed = CaptureTriggerPolicy.cadenceCapSeconds / 2
        let now = epoch.addingTimeInterval(elapsed)
        let decision = decide(trigger: .typingPause(elapsedSeconds: 1), lastCaptureAt: last, now: now)
        #expect(decision == .skip(.cadence(secondsRemaining: CaptureTriggerPolicy.cadenceCapSeconds - elapsed)))
    }

    @Test("Focus and window changes wait only the content-change floor, not the full cadence")
    func contentChangeTriggersUseTighterFloor() {
        let last = epoch
        let justPastFloor = epoch.addingTimeInterval(CaptureTriggerPolicy.contentChangeCadenceFloorSeconds + 0.001)
        #expect(decide(trigger: .textFieldFocused, lastCaptureAt: last, now: justPastFloor) == .capture)
        #expect(decide(trigger: .windowChanged, lastCaptureAt: last, now: justPastFloor) == .capture)
        // Inside the floor they are still blocked — a focus storm cannot
        // capture more than ~2x per second.
        let insideFloor = epoch.addingTimeInterval(CaptureTriggerPolicy.contentChangeCadenceFloorSeconds / 2)
        if case .skip(.cadence) = decide(trigger: .textFieldFocused, lastCaptureAt: last, now: insideFloor) {} else {
            Issue.record("expected cadence skip inside the floor")
        }
        // The typing-pause trigger keeps the full cadence cap.
        let betweenFloors = epoch.addingTimeInterval(1.0)
        if case .skip(.cadence) = decide(trigger: .typingPause(elapsedSeconds: 1), lastCaptureAt: last, now: betweenFloors) {} else {
            Issue.record("expected cadence skip for typing pause at 1s")
        }
    }

    @Test("A capture exactly at the cadence cap boundary is allowed")
    func cadenceCapBoundaryAllows() {
        let last = epoch
        let now = epoch.addingTimeInterval(CaptureTriggerPolicy.cadenceCapSeconds)
        #expect(decide(trigger: .typingPause(elapsedSeconds: 1), lastCaptureAt: last, now: now) == .capture)
    }

    @Test("A capture just past the cadence cap boundary is allowed")
    func cadenceCapPastBoundaryAllows() {
        let last = epoch
        let now = epoch.addingTimeInterval(CaptureTriggerPolicy.cadenceCapSeconds + 0.001)
        #expect(decide(lastCaptureAt: last, now: now) == .capture)
    }

    @Test("Exclusion is checked before cadence, so a fresh capture attempt against an excluded window reports exclusion, not cadence")
    func exclusionOutranksCadence() {
        let last = epoch
        let now = epoch.addingTimeInterval(3) // inside the cadence window too
        let decision = decide(
            visibleWindowOwnerBundleIdentifiers: ["com.1password.1password"],
            excludedApps: ["com.1password.1password"],
            lastCaptureAt: last,
            now: now
        )
        #expect(decision == .skip(.excludedWindow(appBundleIdentifier: "com.1password.1password")))
    }

    @Test("Session-activity window: recent activity reads as active, stale activity does not")
    func sessionActivityWindow() {
        #expect(CaptureTriggerPolicy.isCompletionSessionActive(lastActivityAt: nil, now: epoch) == false)
        #expect(CaptureTriggerPolicy.isCompletionSessionActive(
            lastActivityAt: epoch,
            now: epoch.addingTimeInterval(CaptureTriggerPolicy.sessionActivityWindowSeconds)
        ) == true)
        #expect(CaptureTriggerPolicy.isCompletionSessionActive(
            lastActivityAt: epoch,
            now: epoch.addingTimeInterval(CaptureTriggerPolicy.sessionActivityWindowSeconds + 0.001)
        ) == false)
        // Clock skew guard: activity "in the future" relative to now is not trusted.
        #expect(CaptureTriggerPolicy.isCompletionSessionActive(
            lastActivityAt: epoch.addingTimeInterval(1),
            now: epoch
        ) == false)
    }

    @Test("Password managers are excluded even with an empty user exclusion list")
    func alwaysExcludedAppsBlockWithNoUserConfiguration() {
        #expect(decide(
            visibleWindowOwnerBundleIdentifiers: ["com.1password.1password"],
            excludedApps: []
        ) == .skip(.excludedWindow(appBundleIdentifier: "com.1password.1password")))
        #expect(decide(
            visibleWindowOwnerBundleIdentifiers: ["com.apple.keychainaccess"],
            excludedApps: []
        ) == .skip(.excludedWindow(appBundleIdentifier: "com.apple.keychainaccess")))
    }

    @Test("A visible-but-not-frontmost password manager window still excludes capture")
    func alwaysExcludedAppBehindFocusedWindowStillBlocks() {
        #expect(decide(
            visibleWindowOwnerBundleIdentifiers: ["com.apple.TextEdit", "com.bitwarden.desktop"],
            excludedApps: []
        ) == .skip(.excludedWindow(appBundleIdentifier: "com.bitwarden.desktop")))
    }
}

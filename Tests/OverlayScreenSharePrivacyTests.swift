// OverlayScreenSharePrivacyTests.swift
// Guards that transient Transcripted overlays stay excluded from screen capture
// / screen sharing, while non-sensitive titled app windows stay capturable.
//
// AppKit windows and panels default to `NSWindow.SharingType.readOnly`, which
// ScreenCaptureKit and Screenshot window capture can use. That is the right
// choice for normal windows, where users expect standard macOS screenshots to
// work. Live/transient overlays opt out with `sharingType = .none`.
//
// Every test builds the real window and reads `sharingType` off it. The call
// prompt, meeting pill, dictation overlay and speaker review all draw inside
// the one NotchIslandPanel, so protecting that panel protects them.
//
// Window inventory. This is the list of AppKit windows the app makes, and each
// is built below. Nothing at runtime can say "someone added a window", so a NEW
// NSWindow/NSPanel must be added here by hand with the right policy.
//   protected (.none):      NotchIslandPanel, PasteLastDictationFeedbackPanel
//   capturable (.readOnly): Onboarding window, Settings window

import AppKit
import Foundation

@MainActor
func testOverlayScreenSharePrivacy() async {
    _ = NSApplication.shared

    runSuite("NotchIslandPanel is excluded from screen capture and never takes focus") {
        // Same arguments NotchIslandController.ensurePanel() uses.
        let panel = NotchIslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 32),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        assertEqual(
            panel.sharingType,
            .none,
            "the notch island shows live dictation, the call prompt and meeting status, and must not be visible to screen sharing / capture"
        )
        assertFalse(panel.canBecomeKey, "clicking the island must not pull focus from the app being dictated into")
        assertFalse(panel.canBecomeMain, "the island is never a main window")
        assertEqual(panel.level, .statusBar, "the island sits in the menu bar, above it, below open menus")
        let suiteName = "OverlayScreenSharePrivacyTests.island.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defer { defaults.removePersistentDomain(forName: suiteName) }
            panel.applyScreenSharingPreference(userDefaults: defaults)
            assertEqual(panel.sharingType, .none, "the island stays out of screen sharing by default")
            NotchIslandPreferences.setVisibleInScreenSharing(true, userDefaults: defaults)
            panel.applyScreenSharingPreference(userDefaults: defaults)
            assertEqual(panel.sharingType, .readOnly, "the island becomes capturable once the person turns on Show island in screen sharing")
            NotchIslandPreferences.setVisibleInScreenSharing(false, userDefaults: defaults)
            panel.applyScreenSharingPreference(userDefaults: defaults)
            assertEqual(panel.sharingType, .none, "turning the setting off hides the island again")
        } else {
            assertTrue(false, "expected a scratch UserDefaults suite")
        }
        let offscreen = NSRect(x: 0, y: 5000, width: 360, height: 32)
        assertEqual(
            panel.constrainFrameRect(offscreen, to: nil),
            offscreen,
            "AppKit must not push the island out of the menu bar"
        )
    }

    runSuite("the paste-last-dictation notice panel is excluded from screen capture") {
        let panel = PasteLastDictationFeedbackPresenter().makePanel()
        assertEqual(
            panel.sharingType,
            .none,
            "the paste-last-dictation notice shows dictated text and must not be visible to screen sharing / capture"
        )
        assertFalse(panel.canBecomeKey, "the notice never takes focus")
    }

    runSuite("onboarding stays capturable without displaying a window") {
        let preferredSize = NSSize(width: 640, height: 560)
        let window = TranscriptedOnboardingWindow.make(preferredSize: preferredSize)
        assertEqual(window.sharingType, .readOnly, "first-run setup supports normal macOS screenshots")
        assertFalse(window.isVisible, "constructing onboarding does not show or activate it")
        assertEqual(window.minSize, preferredSize, "preserve onboarding minimum size")
    }

    runSuite("Settings stays capturable without displaying a window") {
        let window = TranscriptedSettingsWindow.make(contentViewController: NSViewController())
        assertEqual(window.sharingType, .readOnly, "Settings supports normal macOS screenshots")
        assertFalse(window.isVisible, "constructing Settings does not show or activate it")
        assertEqual(window.contentMinSize, NSSize(width: 880, height: 640), "preserve Settings minimum size")
    }

    runSuite("detected meeting prompts go to the call prompt on the island") {
        let candidate = overlayPrivacyCandidate(reason: .micInput)
        let controller = CapturePillController()
        assertFalse(
            controller.present(candidate: candidate),
            "with no island there is no other surface to fall back on"
        )

        let island = OverlayPrivacyFakeIsland()
        controller.island = island
        var recorded = 0, reminded = 0, dismissed = 0, expired = 0
        controller.onRecord = { _ in recorded += 1 }
        controller.onRemind = { _ in reminded += 1 }
        controller.onDismiss = { _ in dismissed += 1 }
        controller.onExpired = { _ in expired += 1 }

        assertTrue(controller.present(candidate: candidate, timeout: 45, detailOverride: "Mic only"), "the island shows the prompt")
        assertEqual(
            island.prompt,
            NotchIslandCallPromptContent(title: candidate.title, detail: "Mic only", secondsLeft: 45),
            "the island gets the candidate's title, the detail override and the timeout"
        )
        island.callActionHandler?(.callRemind)
        assertEqual([recorded, reminded, dismissed, expired], [0, 1, 0, 0], "Remind soon uses the remind path")
        assertTrue(island.prompt == nil, "answering clears the prompt")

        _ = controller.present(candidate: candidate)
        island.callActionHandler?(.callRecord)
        assertEqual([recorded, reminded, dismissed, expired], [1, 1, 0, 0], "Record uses the record path")

        _ = controller.present(candidate: candidate)
        island.callActionHandler?(.callDismiss)
        assertEqual([recorded, reminded, dismissed, expired], [1, 1, 1, 0], "Not now is an explicit dismissal, not an expiry")
    }

    runSuite("ad-hoc call prompts get the longer timeout, calendar prompts the default") {
        assertEqual(MeetingPromptHeuristics.promptTimeoutSeconds(for: .micInput, calendarDefault: 30), 60, "mic-led call")
        assertEqual(MeetingPromptHeuristics.promptTimeoutSeconds(for: .audioOutput, calendarDefault: 30), 60, "listen-only call")
        assertEqual(MeetingPromptHeuristics.promptTimeoutSeconds(for: .calendarNearby, calendarDefault: 30), 30, "calendar event")
    }
}

@MainActor
private final class OverlayPrivacyFakeIsland: NotchIslandCallPromptPresenting {
    var callActionHandler: ((NotchIslandAction) -> Void)?
    var callHoverHandler: ((Bool) -> Void)?
    var callVisibilityHandler: ((Bool) -> Void)?
    var prompt: NotchIslandCallPromptContent?
    func updateCallPrompt(_ content: NotchIslandCallPromptContent?) { prompt = content }
    func updateCallPromptSeconds(_ secondsLeft: Int) { prompt?.secondsLeft = secondsLeft }
}

@MainActor
private func overlayPrivacyCandidate(reason: MeetingPromptReason) -> MeetingPromptDetector.Candidate {
    let start = Date(timeIntervalSince1970: 2_000)
    return MeetingPromptDetector.Candidate(
        id: "overlay-privacy-candidate",
        title: "Call detected",
        detail: "Record this call?",
        provider: .zoom,
        reason: reason,
        source: .runtimeApp,
        startDate: start,
        endDate: start.addingTimeInterval(1_800),
        meetingURL: nil,
        suggestedTranscriptTitle: nil
    )
}

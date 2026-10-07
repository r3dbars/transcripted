// OverlayScreenSharePrivacyTests.swift
// Guards that transient Transcripted overlays stay excluded from screen capture
// / screen sharing, while non-sensitive titled app windows stay capturable.
//
// AppKit windows and panels default to `NSWindow.SharingType.readOnly`, which
// ScreenCaptureKit and Screenshot window capture can use. That is the right
// choice for normal windows, where users expect standard macOS screenshots to
// work. Live/transient overlays and transcript-bearing review windows opt out
// with `sharingType = .none`.
//
// NotchIslandPanel (including its Show island in screen sharing switch) and
// PasteLastDictationFeedbackPanel are built live by the suites below. The static parts moved to
// scripts/dev/check-window-capture-policy.py: every new NSWindow/NSPanel being reviewed, the titled
// Onboarding and Settings windows staying capturable, and detected meeting prompts routing through the
// call prompt controller.

import AppKit
import Foundation

@MainActor
func testOverlayScreenSharePrivacy() async {
    // Behavioral: these panels are dependency-free, so the fast runner can
    // instantiate them and assert the real runtime property instead of only
    // inspecting source.
    runSuite("NotchIslandPanel is excluded from screen capture and never takes focus") {
        _ = NSApplication.shared
        let panel = NotchIslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 32),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        assertEqual(
            panel.sharingType,
            .none,
            "the notch island shows live dictation and must not be visible to screen sharing / capture"
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

    runSuite("PasteLastDictationFeedbackPanel is excluded from screen capture") {
        _ = NSApplication.shared
        let panel = PasteLastDictationFeedbackPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 56),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        assertEqual(
            panel.sharingType,
            .none,
            "the paste-last-dictation notice shows dictated text and must not be visible to screen sharing / capture"
        )
    }
}

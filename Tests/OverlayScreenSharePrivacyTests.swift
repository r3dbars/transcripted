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
// Source-text pins left: "protected Transcripted NSWindow/NSPanel inits" and
// "non-sensitive titled windows stay capturable" read the init bodies of
// MeetingOverlayPanel/MeetingOverlayTooltipPanel, NamingWindowController
// (SpeakerNamingSheet.swift), TranscriptedOnboardingWindowController and
// TranscriptedSettingsWindowController as text. The meeting pill and naming
// window are deleted by the #1946 follow-ups; the two window controllers need
// the live app graph (or a window factory seam) this runner never builds.
// "detected meeting prompts route through the capture pill" reads
// TranscriptedApp.swift, which another lane is splitting; convert it after.
// The window/panel marker scan is a legitimate static check: there is no
// runtime signal for "a new window got added", so update expectedMarkers when
// you add, rename, or remove one.
//
// Built for real: FloatingOverlayPanel, CapturePillPanel, NotchIslandPanel
// (including its screen-sharing switch) and PasteLastDictationFeedbackPanel.
// The call prompt's Return/Escape scoping runs through CapturePillKeyRouting.

import AppKit
import Foundation

@MainActor
func testOverlayScreenSharePrivacy() async {
    // Behavioral: these panels are dependency-free, so the fast runner can
    // instantiate them and assert the real runtime property instead of only
    // inspecting source.
    runSuite("FloatingOverlayPanel is excluded from screen capture") {
        _ = NSApplication.shared
        let panel = FloatingOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        assertEqual(
            panel.sharingType,
            .none,
            "the dictation overlay must not be visible to screen sharing / capture"
        )
    }

    runSuite("CapturePillPanel is excluded from screen capture") {
        _ = NSApplication.shared
        let panel = CapturePillPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 74),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        assertEqual(
            panel.sharingType,
            .none,
            "the capture pill must not be visible to screen sharing / capture"
        )
        assertTrue(panel.canBecomeKey, "the capture pill must be keyboard-dismissable")
    }

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

    runSuite("CapturePillController scopes Return and Escape to the pill panel") {
        func route(_ keyCode: UInt16, visible: Bool = true, inPill: Bool = false, isKey: Bool = false) -> CapturePillKeyRouting {
            CapturePillKeyRouting.action(keyCode: keyCode, pillVisible: visible, eventInPill: inPill, pillIsKey: isKey)
        }
        assertEqual(route(CapturePillKeyRouting.returnKeyCode, inPill: true), .record, "Return in the pill records")
        assertEqual(route(CapturePillKeyRouting.escapeKeyCode, inPill: true), .dismiss, "Escape in the pill dismisses")
        assertEqual(route(CapturePillKeyRouting.returnKeyCode, isKey: true), .record, "Return while the pill is key records")
        assertEqual(route(CapturePillKeyRouting.escapeKeyCode, isKey: true), .dismiss, "Escape while the pill is key dismisses")
        assertEqual(
            route(CapturePillKeyRouting.returnKeyCode),
            .passThrough,
            "Return typed into Home, Settings, or a speaker-review field must reach that window, not the pill"
        )
        assertEqual(
            route(CapturePillKeyRouting.escapeKeyCode),
            .passThrough,
            "Escape aimed at another Transcripted window must not dismiss the call prompt"
        )
        assertEqual(
            route(CapturePillKeyRouting.escapeKeyCode, visible: false, inPill: true, isKey: true),
            .passThrough,
            "a hidden pill handles no keys"
        )
        assertEqual(route(0, inPill: true, isKey: true), .passThrough, "other keys always pass through")
    }

    // Source contract: most app surfaces live in files the fast runner cannot
    // compile in isolation, so guard their init bodies at the source level.
    runSuite("protected Transcripted NSWindow/NSPanel inits set sharingType = .none") {
        // FloatingOverlayPanel, CapturePillPanel, and NotchIslandPanel are
        // compiled here and built for real by the suites above; only the
        // surfaces this runner cannot construct stay on this source table.
        let panelSource = overlayPrivacySource("Sources/UI/Overlay/MeetingOverlayPanel.swift")
        let speakerNaming = overlayPrivacySource("Sources/UI/Settings/SpeakerNamingSheet.swift")
        let inits: [(name: String, body: String)] = [
            (
                "MeetingOverlayPanel",
                overlayPrivacySlice(
                    panelSource,
                    from: "final class MeetingOverlayPanel: NSPanel {",
                    to: "final class MeetingOverlayTooltipPanel"
                )
            ),
            (
                "MeetingOverlayTooltipPanel",
                overlayPrivacySlice(
                    panelSource,
                    from: "final class MeetingOverlayTooltipPanel: NSPanel {",
                    to: "final class MeetingOverlayTooltipView"
                )
            ),
            (
                "NamingWindowController",
                overlayPrivacySlice(
                    speakerNaming,
                    from: "let window = NSWindow(",
                    to: "super.init(window: window)"
                )
            ),
        ]

        for entry in inits {
            assertTrue(
                entry.body.contains("sharingType = .none"),
                "\(entry.name) init must set sharingType = .none so the surface stays out of screen capture"
            )
        }
    }

    runSuite("non-sensitive titled Transcripted windows stay capturable") {
        let onboardingWindow = overlayPrivacySource("Sources/UI/Settings/TranscriptedOnboardingWindowController.swift")
        let settingsWindow = overlayPrivacySource("Sources/UI/Settings/TranscriptedSettingsWindowController.swift")

        let inits: [(name: String, body: String)] = [
            (
                "TranscriptedOnboardingWindowController",
                overlayPrivacySlice(
                    onboardingWindow,
                    from: "let window = NSWindow(",
                    to: "super.init(window: window)"
                )
            ),
            (
                "TranscriptedSettingsWindowController",
                overlayPrivacySlice(
                    settingsWindow,
                    from: "let window = NSWindow(",
                    to: "super.init(window: window)"
                )
            ),
        ]

        for entry in inits {
            assertTrue(
                entry.body.contains("sharingType = .readOnly"),
                "\(entry.name) should support normal macOS screenshots"
            )
            assertFalse(
                entry.body.contains("sharingType = .none"),
                "\(entry.name) must not opt itself out of screenshots"
            )
        }
    }

    runSuite("new NSWindow/NSPanel surfaces must be reviewed by the capture policy contract") {
        let expectedMarkers: [String] = [
            "Sources/UI/MenuBar/PasteLastDictationFeedback.swift|final class PasteLastDictationFeedbackPanel: NSPanel {",
            "Sources/UI/Overlay/CapturePillController.swift|final class CapturePillPanel: NSPanel {",
            "Sources/UI/Overlay/FloatingOverlayPanel.swift|class FloatingOverlayPanel: NSPanel {",
            "Sources/UI/Overlay/MeetingOverlayPanel.swift|final class MeetingOverlayPanel: NSPanel {",
            "Sources/UI/Overlay/MeetingOverlayPanel.swift|final class MeetingOverlayTooltipPanel: NSPanel {",
            "Sources/UI/Overlay/NotchIslandPanel.swift|final class NotchIslandPanel: NSPanel {",
            "Sources/UI/Settings/SpeakerNamingSheet.swift|let window = NSWindow(",
            "Sources/UI/Settings/TranscriptedOnboardingWindowController.swift|let window = NSWindow(",
            "Sources/UI/Settings/TranscriptedSettingsWindowController.swift|let window = NSWindow(",
        ]
        let markers = overlayPrivacyWindowPanelMarkers()
        assertEqual(
            markers,
            expectedMarkers,
            "any new Transcripted NSWindow/NSPanel must be reviewed here and classified as protected or capturable"
        )
    }

    runSuite("detected meeting prompts route through the capture pill") {
        let app = overlayPrivacySource("Sources/TranscriptedApp.swift")
        let promptRequest = overlayPrivacySlice(
            app,
            from: "meetingPromptDetector.onPromptRequest =",
            to: "// Ad-hoc call detection:"
        )
        assertTrue(
            promptRequest.contains("capturePillController.present("),
            "detected meeting prompts should use the floating capture pill"
        )
        assertTrue(
            promptRequest.contains("MeetingPromptHeuristics.promptTimeoutSeconds"),
            "detected meeting prompts should preserve calendar vs ad-hoc prompt timeouts"
        )
        assertTrue(
            app.contains("capturePillController.onRemind = remindPrompt"),
            "the capture pill should expose the short remind-soon path"
        )
        assertTrue(
            app.contains("capturePillController.onExpired = expirePrompt"),
            "the capture pill timeout should use the expiry path, not an explicit dismissal"
        )
        assertFalse(
            promptRequest.contains("meetingOverlayController.presentDetectedMeetingPrompt(candidate)"),
            "detected meeting prompts should not reuse the recording overlay prompt surface"
        )
    }
}

private func overlayPrivacySource(_ relativePath: String) -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func overlayPrivacySlice(_ contents: String, from start: String, to end: String) -> String {
    guard let startRange = contents.range(of: start) else { return "" }
    let tail = contents[startRange.upperBound...]
    guard let endRange = tail.range(of: end) else { return String(tail) }
    return String(tail[..<endRange.lowerBound])
}

private func overlayPrivacyWindowPanelMarkers() -> [String] {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("Sources/UI")
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil
    ) else { return [] }

    var markers: [String] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
        let relativePath = "Sources/UI/" + url.path.replacingOccurrences(of: root.path + "/", with: "")
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let isWindowOrPanelClass = (
                line.hasPrefix("class ")
                    || line.hasPrefix("final class ")
                    || line.hasPrefix("private final class ")
            ) && line.contains(": NSPanel")
            if isWindowOrPanelClass || line.contains("NSPanel(") || line.contains("NSWindow(") {
                markers.append("\(relativePath)|\(line)")
            }
        }
    }
    return markers.sorted()
}

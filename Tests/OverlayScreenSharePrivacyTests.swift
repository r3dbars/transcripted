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
// Source-text pins: "protected Transcripted NSWindow/NSPanel inits" and "non-sensitive titled windows
// stay capturable" below read Sources/UI/Overlay/MeetingOverlayPanel.swift
// and Sources/UI/Settings/{SpeakerNamingSheet,
// TranscriptedOnboardingWindowController,TranscriptedSettingsWindowController}.swift as text instead of
// constructing every surface. TranscriptedSettingsWindowController needs a live TranscriptedAppState/TranscriptedSettingsActions object
// graph (STTRouter, MeetingSessionController, SparkleUpdaterController...) this runner never builds —
// TranscriptedOnboardingWindowController's init only takes closures (makeView returning
// PermissionsOnboardingView, itself needing just onComplete) and looks just as constructible, but is kept
// in the same table rather than special-cased; NamingWindowController needs a real SpeakerNamingRequest.
// CapturePillPanel, NotchIslandPanel, and PasteLastDictationFeedbackPanel are
// compiled here and built live by the first three suites, so they are not on the source table. MeetingOverlayPanel/MeetingOverlayTooltipPanel
// live in a file this runner does not compile, so they stay on it. The CapturePillController suite greps
// present()/installEventMonitor() because proving real Return/Escape key routing needs a live
// NSApplication event loop delivering NSEvents, which this fast runner doesn't drive. The last suite
// (overlayPrivacyWindowPanelMarkers) is inherently static — it walks Sources/UI for every NSWindow/NSPanel
// definition and diffs against a fixed allowlist, since there's no runtime signal for "a new window got
// added" — update expectedMarkers when you add, rename, or remove one.

import AppKit
import Foundation

@MainActor
func testOverlayScreenSharePrivacy() async {
    // Behavioral: these panels are dependency-free, so the fast runner can
    // instantiate them and assert the real runtime property instead of only
    // inspecting source.
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
        let controller = overlayPrivacySource("Sources/UI/Overlay/NotchIslandController.swift")
        assertTrue(
            controller.contains("panel.sharingType = NotchIslandPreferences.visibleInScreenSharing() ? .readOnly : .none"),
            "the island only becomes capturable when the person turns on Show island in screen sharing"
        )
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
        let capturePill = overlayPrivacySource("Sources/UI/Overlay/CapturePillController.swift")
        let presentBlock = overlayPrivacySlice(
            capturePill,
            from: "func present(",
            to: "func dismiss(notify: Bool)"
        )
        let monitorBlock = overlayPrivacySlice(
            capturePill,
            from: "private func installEventMonitor()",
            to: "private func position(panel: NSPanel)"
        )

        assertFalse(
            presentBlock.contains("panel.makeKey()"),
            "showing the detected-meeting pill must not steal key focus from the current Transcripted window"
        )
        assertTrue(
            monitorBlock.contains("event.window === panel || panel.isKeyWindow")
                && monitorBlock.contains("case 36:")
                && monitorBlock.contains("case 53:")
                && monitorBlock.contains("return event"),
            "Return/Escape should be swallowed only when the key event belongs to the pill panel"
        )
    }

    // Source contract: most app surfaces live in files the fast runner cannot
    // compile in isolation, so guard their init bodies at the source level.
    runSuite("protected Transcripted NSWindow/NSPanel inits set sharingType = .none") {
        // CapturePillPanel and NotchIslandPanel are
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
        let meetingOverlay = overlayPrivacySource("Sources/UI/Overlay/MeetingOverlayController.swift")
        assertFalse(
            meetingOverlay.contains("presentDetectedMeetingPrompt")
                || meetingOverlay.contains("onPromptRecord")
                || meetingOverlay.contains("onPromptDismiss")
                || meetingOverlay.contains("onPromptRemindSoon")
                || meetingOverlay.contains("onPromptExpired"),
            "the recording overlay should not retain a second detected-meeting prompt implementation"
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

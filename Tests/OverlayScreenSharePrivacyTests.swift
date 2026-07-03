// OverlayScreenSharePrivacyTests.swift
// Guards that every floating overlay panel is excluded from screen capture /
// screen sharing.
//
// AppKit panels default to `NSWindow.SharingType.readOnly`, which
// ScreenCaptureKit happily captures. For a tool whose whole premise is
// privately recording a call, that default is a trust failure: a user sharing
// their screen during a recorded meeting could unintentionally broadcast live
// transcript text. The fix sets `sharingType = .none` in every overlay NSPanel
// init; this test makes that property a regression-guarded invariant.

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

    // Source contract: the two meeting-overlay panels live in a heavy controller
    // file the fast runner cannot compile in isolation, so guard their init
    // bodies at the source level. The on-screen live transcript drawer renders
    // inside MeetingOverlayPanel, and the hover tooltip inside
    // MeetingOverlayTooltipPanel. Both must stay out of screen capture.
    runSuite("every overlay NSPanel init sets sharingType = .none") {
        let floating = overlayPrivacySource("Sources/UI/Overlay/FloatingOverlayPanel.swift")
        let capturePill = overlayPrivacySource("Sources/UI/Overlay/CapturePillController.swift")
        let controller = overlayPrivacySource("Sources/UI/Overlay/MeetingOverlayController.swift")

        let inits: [(name: String, body: String)] = [
            (
                "FloatingOverlayPanel",
                overlayPrivacySlice(
                    floating,
                    from: "class FloatingOverlayPanel: NSPanel {",
                    to: "override var canBecomeKey"
                )
            ),
            (
                "CapturePillPanel",
                overlayPrivacySlice(
                    capturePill,
                    from: "final class CapturePillPanel: NSPanel {",
                    to: "private final class CapturePillView"
                )
            ),
            (
                "MeetingOverlayPanel",
                overlayPrivacySlice(
                    controller,
                    from: "final class MeetingOverlayPanel: NSPanel {",
                    to: "final class MeetingOverlayTooltipPanel"
                )
            ),
            (
                "MeetingOverlayTooltipPanel",
                overlayPrivacySlice(
                    controller,
                    from: "final class MeetingOverlayTooltipPanel: NSPanel {",
                    to: "final class MeetingOverlayTooltipView"
                )
            ),
        ]

        for entry in inits {
            assertTrue(
                entry.body.contains("self.sharingType = .none"),
                "\(entry.name) init must set self.sharingType = .none so the overlay stays out of screen capture"
            )
        }
    }

    runSuite("detected meeting prompts route through the capture pill") {
        let app = overlayPrivacySource("Sources/TranscriptedApp.swift")
        let promptRequest = overlayPrivacySlice(
            app,
            from: "meetingPromptDetector.onPromptRequest =",
            to: "// Ad-hoc call detection:"
        )
        assertTrue(
            promptRequest.contains("capturePillController.present(candidate: candidate)"),
            "detected meeting prompts should use the floating capture pill"
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

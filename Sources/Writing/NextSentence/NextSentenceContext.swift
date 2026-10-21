import TranscriptedWritingCore

import AppKit
import ScreenCaptureKit

/// What Next Sentence knows about the moment the hotkey was pressed. Memory-only: nothing here is
/// written to disk or logged; the owner-only Claude mode sends it to Claude (see NextSentencePreferences).
struct NextSentenceSnapshot: Sendable {
    var appName: String
    var bundleIdentifier: String?
    var processIdentifier: pid_t
    var windowTitle: String
    /// What's already typed in the focused field.
    var draft: String
    /// The focused window's text, read the way Screen Memory reads it.
    var screenText: String
    /// The focused window only, scaled down, JPEG.
    var screenshotJPEG: Data?
    /// The text cursor in Accessibility screen coordinates (top-left origin).
    var caret: CGRect?
}

enum NextSentenceCaptureBlock: Equatable {
    case noFrontmostApp
    case ownApp
    case excludedApp
}

@MainActor
enum NextSentenceContext {
    /// Same refusals as Screen Memory: never Transcripted itself, never a password manager.
    static func blockReason(for app: NSRunningApplication?) -> NextSentenceCaptureBlock? {
        guard let app else { return .noFrontmostApp }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return .ownApp }
        if let bundle = app.bundleIdentifier, DefaultExcludedApps.isAlwaysExcluded(bundle) { return .excludedApp }
        return nil
    }

    /// The quick part, on the main actor: field text and cursor. Enough to place the card at once.
    static func captureFocus(of app: NSRunningApplication) -> NextSentenceSnapshot {
        NextSentenceSnapshot(
            appName: app.localizedName ?? "",
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            windowTitle: "",
            draft: String((AccessibilityBridge.focusedText(for: app) ?? "").suffix(4_000)),
            screenText: "",
            screenshotJPEG: nil,
            caret: AccessibilityBridge.focusedCaretRect(for: app)
        )
    }

    /// The slower part, off the main actor: the window's screenshot and text.
    static func captureWindow(into snapshot: NextSentenceSnapshot) async -> NextSentenceSnapshot {
        var snapshot = snapshot
        let window = await NextSentenceWindowCapture.capture(pid: snapshot.processIdentifier)
        snapshot.screenshotJPEG = window?.jpeg
        snapshot.screenText = window?.text ?? ""
        snapshot.windowTitle = window?.title ?? ""
        return snapshot
    }
}

/// One window, captured with ScreenCaptureKit and read with Screen Memory's Accessibility reader.
enum NextSentenceWindowCapture {
    struct Result: Sendable {
        let jpeg: Data?
        let text: String
        let title: String
    }

    static let maxWidth: CGFloat = 1_280

    static func capture(pid: pid_t) async -> Result? {
        guard ScreenRecordingPermission.isGranted() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            // Front to back: the app's frontmost normal window.
            guard let window = content.windows.first(where: {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0
                    && $0.frame.width > 200 && $0.frame.height > 120
            }) else { return nil }
            let display = content.displays.first { $0.frame.intersects(window.frame) } ?? content.displays.first

            async let jpeg = screenshot(window)
            let text: String = await Task.detached(priority: .userInitiated) {
                guard let display, let read = AXWindowTextReader.read(for: window, display: display) else { return "" }
                return read.blocks.map(\.text).joined(separator: "\n")
            }.value
            return Result(jpeg: await jpeg, text: String(text.suffix(6_000)), title: window.title ?? "")
        } catch {
            return nil
        }
    }

    private static func screenshot(_ window: SCWindow) async -> Data? {
        let scale = min(1, maxWidth / max(window.frame.width, 1))
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config
        ) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }
}

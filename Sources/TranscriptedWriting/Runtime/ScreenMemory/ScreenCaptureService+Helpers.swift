#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Pure helpers for `ScreenCaptureService`: refusal mapping, pixel math,
/// and window geometry. Moved out of the actor file to keep it small; none
/// of these touch actor state.
extension ScreenCaptureService {
    /// The outcome a refusal returns. An app outside the scope reads as
    /// excluded, since for Screen Memory that's what it is; anything else
    /// means the focused window couldn't be proven.
    static func blockReason(for refusal: FocusedWindowCapturePolicy.Refusal) -> CaptureTriggerPolicy.BlockReason {
        switch refusal {
        case let .excluded(bundleIdentifier), let .outOfScope(bundleIdentifier):
            return .excludedWindow(appBundleIdentifier: bundleIdentifier)
        case .noTarget, .ownApp, .windowNotVisible, .ownerMismatch, .notNormalWindow, .unknownApp,
             .notFrontmostApp, .keyboardFocusElsewhere, .keyboardFocusUnknown, .notFocusedWindow:
            return .noTargetWindow
        }
    }

    /// The logged `reason` for a refusal: a fixed string per case, all in
    /// `DiagnosticsMetadataRedactor`'s allowlist. Never a bundle ID, title
    /// or path.
    static func skipReason(for refusal: FocusedWindowCapturePolicy.Refusal) -> String {
        switch refusal {
        case .noTarget: return "no-target-window"
        case .ownApp: return "own-app"
        case .windowNotVisible: return "window-not-visible"
        case .ownerMismatch: return "owner-mismatch"
        case .notNormalWindow: return "not-normal-window"
        case .unknownApp: return "unknown-app"
        case .excluded: return "excluded-app"
        case .outOfScope: return "out-of-scope"
        case .notFrontmostApp: return "not-frontmost-app"
        case .keyboardFocusElsewhere: return "keyboard-focus-elsewhere"
        case .keyboardFocusUnknown: return "keyboard-focus-unknown"
        case .notFocusedWindow: return "not-focused-window"
        }
    }

    /// Whole milliseconds between two instants, floored at zero so a clock
    /// that does not advance (the common case in tests, which hold `now`
    /// fixed) reports `0` rather than a negative number. Internal, not
    /// private, so `ScreenCaptureServiceTests` can prove the rounding/floor
    /// behavior directly — `performCapture` itself stays untestable at unit
    /// level like the rest of ScreenCaptureKit-shaped code in this type (see
    /// the type doc comment), so this is the one piece of the duty-cycle
    /// math that CAN be proven without a live display.
    /// Backing pixels per point for the display being captured; 2 on
    /// Retina panels, 1 otherwise. Falls back to 1 when the display has no
    /// pixel dimensions (mirrored/virtual displays during setup).
    static func pixelScale(of display: SCDisplay) -> Double {
        // `CGDisplayPixelsWide` reports the LOGICAL width in scaled Retina
        // modes (it equals `display.width`), which is exactly the 1x trap
        // this helper exists to avoid. The display mode carries the true
        // backing size.
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        return pixelScale(pixelWidth: mode?.pixelWidth ?? 0, pointWidth: display.width)
    }

    static func pixelScale(pixelWidth: Int, pointWidth: Int) -> Double {
        guard pixelWidth > 0, pointWidth > 0 else { return 1 }
        return max(1, (Double(pixelWidth) / Double(pointWidth)).rounded())
    }

    static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    static func aggregateConfidence(of blocks: [ScreenSnapshot.TextBlock]) -> Double {
        let values = blocks.compactMap(\.confidence)
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    static func describe(_ reason: CaptureTriggerPolicy.BlockReason) -> String {
        switch reason {
        case .disabled: return "disabled"
        case .screenLocked: return "screen-locked"
        case .secureInput: return "secure-input"
        case .noActiveTextField: return "no-active-text-field"
        case .noActiveCompletionSession: return "no-active-session"
        case .belowTypingPauseThreshold: return "below-threshold"
        case .excludedWindow: return "excluded-app"
        case .cadence: return "cadence"
        case .noTargetWindow: return "no-target-window"
        case .targetChanged: return "target-changed"
        }
    }

    static func display(containing window: SCWindow, in displays: [SCDisplay]) -> SCDisplay? {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        return displays.first(where: { $0.frame.contains(center) }) ?? displays.first
    }

    /// True front-to-back ranks for on-screen windows, from
    /// `CGWindowListCopyWindowInfo` — the one window API whose ordering IS
    /// documented ("returned in order from front to back"). Keyed by
    /// `CGWindowID` for lookup against `SCWindow.windowID`.
    static func onScreenZOrderRanks() -> [CGWindowID: Int] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }
        var ranks: [CGWindowID: Int] = [:]
        for (rank, entry) in info.enumerated() {
            if let number = entry[kCGWindowNumber as String] as? NSNumber {
                ranks[CGWindowID(truncating: number)] = rank
            }
        }
        return ranks
    }

    /// `SCWindow.frame` is in global desktop points; `display.frame` is that
    /// same display's placement in that same global space. Normalizing by
    /// the display's own frame — not (0,0)-(screenWidth,screenHeight)) —
    /// keeps multi-monitor arrangements correct: a window's frame is
    /// expressed relative to the display it was captured from, matching the
    /// 0...1 space Vision's OCR boxes already use for that capture.
    static func normalize(_ frame: CGRect, in displayFrame: CGRect) -> NormalizedDisplayRect {
        guard displayFrame.width > 0, displayFrame.height > 0 else {
            return NormalizedDisplayRect(x: 0, y: 0, width: 0, height: 0)
        }
        return NormalizedDisplayRect(
            x: (frame.origin.x - displayFrame.origin.x) / displayFrame.width,
            y: (frame.origin.y - displayFrame.origin.y) / displayFrame.height,
            width: frame.width / displayFrame.width,
            height: frame.height / displayFrame.height
        )
    }
}

import ApplicationServices
import Foundation

/// The TCC gate for exact screen text: macOS Accessibility permission lets
/// `AXWindowTextReader` read the focused window's text as exact strings
/// with true frames instead of OCR. Reading only, under the Screen Memory
/// covenant — Tilde never inserts text through Accessibility. Every check
/// here is graceful: nothing blocks or crashes if the user has never been
/// asked, has denied, or revokes access later; the capture path simply
/// falls back to OCR exactly as it does today.
enum AccessibilityPermission {
    /// Non-prompting check, safe on every trigger.
    static func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt the first time it is called for this code
    /// signature and lists the app in the Accessibility pane; a no-op that
    /// returns the current state once the user has answered. macOS grants
    /// access asynchronously, so `isGranted()` reflects it on a later check.
    @discardableResult
    static func request() -> Bool {
        // The literal spelling of `kAXTrustedCheckOptionPrompt`: the global is
        // a mutable CFString the concurrency checker refuses to touch.
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Deep link into System Settings' Accessibility pane, for the case
    /// where the prompt was dismissed and will not reappear.
    static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!
}

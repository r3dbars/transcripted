import AppKit
import ApplicationServices

/// Who has focus right now, for `FocusedWindowCapturePolicy`. Reads process
/// IDs only, never a window title, a UI element's value, or any text.
enum KeyboardFocusProbe {
    /// The active app's process ID, or nil when there's none.
    static func frontmostApplicationProcessIdentifier() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// The process Accessibility reports as having keyboard focus. This can
    /// differ from the frontmost app when a non-activating panel (a launcher,
    /// a floating search field) takes the keyboard. Nil when Accessibility
    /// isn't granted or the system doesn't answer; the policy then refuses
    /// the capture.
    ///
    /// Asks the system-wide element for the focused *application* only. It
    /// never sets a messaging timeout on the system-wide element: that call
    /// changes the timeout for every Accessibility element in the process.
    static func keyboardFocusProcessIdentifier() -> Int32? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(value as! AXUIElement, &processIdentifier) == .success,
              processIdentifier > 0 else { return nil }
        return processIdentifier
    }
}

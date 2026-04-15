// AccessibilityBridge.swift
// AXUIElement queries for text field position, value, and element lookup

import AppKit
import ApplicationServices

@MainActor
struct AccessibilityBridge {

    /// Return the focused text element in the given app, or nil if not a text field.
    static func focusedTextElement(for app: NSRunningApplication) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }

        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard result == .success, let focusedElement = focusedRef else { return nil }

        let axElement = focusedElement as! AXUIElement

        // Check if it's a text-related element
        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        // Never expose secure text fields (password, PIN, biometric auth). The
        // broader "contains Text" match below would otherwise accept AXSecureTextField.
        if role == "AXSecureTextField" { return nil }

        let textRoles = ["AXTextArea", "AXTextField", "AXWebArea", "AXTextView", "AXComboBox"]
        guard textRoles.contains(role) || role.contains("Text") else { return nil }

        return axElement
    }

    /// Read the text value of an AX element (kAXValueAttribute).
    static func textValue(of element: AXUIElement) -> String? {
        var valueRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        guard result == .success else { return nil }
        return valueRef as? String
    }

    /// Find the screen rect of the focused text field in the given app.
    static func focusedTextFieldRect(for app: NSRunningApplication) -> CGRect? {
        guard let axElement = focusedTextElement(for: app) else { return nil }

        var posRef: AnyObject?
        var sizeRef: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeRef)

        guard let posValue = posRef, let sizeValue = sizeRef else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }
}

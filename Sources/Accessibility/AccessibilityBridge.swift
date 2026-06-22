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

        guard let axElement = axElement(from: focusedElement) else { return nil }

        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        var subroleRef: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String

        guard acceptsFocusedTextRole(role, subrole: subrole) else { return nil }

        return axElement
    }

    nonisolated static func acceptsFocusedTextRole(_ role: String, subrole: String?) -> Bool {
        AccessibilityFocusedTextPolicy.accepts(role: role, subrole: subrole)
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

        guard let posValue = axValue(from: posRef),
              let sizeValue = axValue(from: sizeRef) else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }

    private static func axElement(from value: AnyObject) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func axValue(from value: AnyObject?) -> AXValue? {
        guard let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
}

private enum AccessibilityFocusedTextPolicy {
    private static let secureTextFieldRole = "AXSecureTextField"
    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXWebArea", "AXTextView", "AXComboBox"]

    static func accepts(role: String, subrole: String?) -> Bool {
        // Never expose secure text fields (password, PIN, biometric auth). Some
        // AppKit hosts surface secure fields as AXTextField with subrole
        // AXSecureTextField, so we check both the role and the subrole.
        guard role != secureTextFieldRole, subrole != secureTextFieldRole else {
            return false
        }

        return textRoles.contains(role) || role.contains("Text")
    }
}

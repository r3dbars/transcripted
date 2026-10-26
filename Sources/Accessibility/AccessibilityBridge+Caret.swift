// AccessibilityBridge+Caret.swift
// Where the text cursor is and what's already typed in the focused field, for Next Sentence.

import AppKit
import ApplicationServices

extension AccessibilityBridge {
    /// The focused field's text, or nil when it isn't a text field (secure fields included).
    static func focusedText(for app: NSRunningApplication) -> String? {
        guard let element = focusedTextElement(for: app) else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    /// The text cursor's rect in Accessibility screen coordinates (top-left origin), or the
    /// focused field's first line when the app won't report the cursor. Nil when neither is known.
    static func focusedCaretRect(for app: NSRunningApplication) -> CGRect? {
        guard let element = focusedTextElement(for: app) else { return nil }
        var rangeRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let range = rangeRef, CFGetTypeID(range) == AXValueGetTypeID() {
            var boundsRef: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &boundsRef
            ) == .success, let bounds = boundsRef, CFGetTypeID(bounds) == AXValueGetTypeID() {
                var rect = CGRect.zero
                // Some apps answer with a zero rect at the origin; that's no answer.
                if AXValueGetValue(unsafeBitCast(bounds, to: AXValue.self), .cgRect, &rect),
                   rect.height > 0, rect.origin != .zero {
                    return rect
                }
            }
        }
        guard let field = focusedTextFieldRect(for: app) else { return nil }
        return NextSentenceCaretFallback.firstLine(of: field)
    }
}

/// When an app won't say where the cursor is, aim at the field's first line, where new text goes.
enum NextSentenceCaretFallback {
    static func firstLine(of field: CGRect) -> CGRect {
        CGRect(x: field.minX + 8, y: field.minY, width: 2, height: min(field.height, 24))
    }
}

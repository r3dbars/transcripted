# Accessibility Bridge

## What This Does

Static utility for querying macOS Accessibility (AXUIElement) APIs. Provides text field detection, value reading, and screen rect lookup for the focused element in any running application. Used by `FloatingOverlayController` to position the floating overlay near the user's active text field.

## Key Files

- `AccessibilityBridge.swift` (~61 lines) — `@MainActor` struct with 3 static methods for AXUIElement queries

## Public Interface

```swift
/// Return the focused text element in the given app, or nil if not a text field.
/// Checks AXRole against: AXTextArea, AXTextField, AXWebArea, AXTextView, AXComboBox,
/// or any role containing "Text".
static func focusedTextElement(for app: NSRunningApplication) -> AXUIElement?

/// Read the text value (kAXValueAttribute) of an AX element.
static func textValue(of element: AXUIElement) -> String?

/// Find the screen rect (position + size) of the focused text field in the given app.
/// Combines focusedTextElement() with kAXPositionAttribute and kAXSizeAttribute.
static func focusedTextFieldRect(for app: NSRunningApplication) -> CGRect?
```

## AXUIElement Usage Patterns

1. **App element from PID** — `AXUIElementCreateApplication(pid)` creates the root accessibility element for a process
2. **Focused element lookup** — `AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute, &ref)` retrieves whatever element has keyboard focus
3. **Role check** — `kAXRoleAttribute` is read to filter for text-capable elements only (prevents positioning against non-text controls like buttons)
4. **Position/Size extraction** — `kAXPositionAttribute` and `kAXSizeAttribute` return `AXValue` refs that must be unwrapped via `AXValueGetValue(_:_:_:)` into `CGPoint` and `CGSize`

## AXIsProcessTrusted Guard

Every entry point checks `AXIsProcessTrusted()` first. If the app lacks Accessibility permission, all methods return `nil` silently. The permission prompt is triggered separately in `DraftSessionController.pasteWithClipboardRestore()` using `AXIsProcessTrustedWithOptions` with the prompt flag.

## Who Uses This

- **`FloatingOverlayController.showPanel(near:)`** — Calls `focusedTextFieldRect(for:)` to position the overlay above the user's cursor in the target app. Falls back to mouse cursor positioning when the rect is nil or oversized (terminal emulators like iTerm2 report their entire scrollback buffer as the text area rect).

## Gotchas

- **CF type casts** — `posValue as! AXValue` uses force-cast, which is safe because CoreFoundation bridged types always succeed at the `as?`/`as!` level. See project-wide learning in root CLAUDE.md.
- **Coordinate system** — AXUIElement returns screen coordinates in the macOS top-left-origin coordinate system (origin at top-left of primary display). `FloatingOverlayController` must flip Y coordinates to AppKit's bottom-left-origin system before positioning the panel.
- **Oversized rects** — Some apps (especially terminal emulators) report their entire scrollable content area as the focused text field rect, producing heights like 4000px on a 1000px screen. `FloatingOverlayController` validates the rect against screen dimensions and falls back to mouse positioning if invalid.
- **Permission dependency** — Accessibility permission is an all-or-nothing system-level toggle. If revoked at runtime, all AX queries silently fail. The app does not currently detect or surface this revocation to the user (it just falls back to mouse positioning).

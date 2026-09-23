// BrowserWindowTitleReader.swift
// Reads the window titles of the browsers that hold the mic, through the
// Accessibility permission Transcripted already has for paste-back. Feeds
// `BrowserCallEvidence.classify`.
//
// Privacy: titles are returned to the caller, classified in memory, and
// dropped. This file never logs, stores, or reports them. Without
// Accessibility (`AXIsProcessTrusted() == false`) it returns nothing and the
// detector falls back to its timing rules; it never asks for the permission.
//
// Only window titles are read (`kAXWindowsAttribute` + `kAXTitleAttribute` on
// the app element), never page content, and every round trip is bounded by a
// short messaging timeout so a hung browser cannot stall the main actor.

import AppKit
import ApplicationServices

@MainActor
enum BrowserWindowTitleReader {
    /// Per-app bound on each AX round trip. Titles are a nice-to-have; a slow
    /// answer just means "unknown", which falls back to the timing rules.
    private static let messagingTimeout: Float = 0.25
    /// Enough for any real window layout; stops a pathological app from
    /// making us walk hundreds of windows.
    private static let maxWindowsPerApp = 24

    /// Titles of every window of the running browser apps in `families`
    /// (bundle-family prefixes from `MeetingPromptProvider.browserBundleIDPrefixes`).
    static func titles(forBrowserFamilies families: Set<String>) -> [BrowserWindowTitle] {
        guard !families.isEmpty, AXIsProcessTrusted() else { return [] }

        let appFamilies = Set(families.map(MeetingPromptProvider.browserAppFamily(forBundleFamily:)))
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier else { return false }
            return appFamilies.contains { bundleID.matchesBundleFamily($0) }
        }

        var titles: [BrowserWindowTitle] = []
        for app in apps {
            titles.append(contentsOf: windowTitles(for: app))
        }
        return titles
    }

    private static func windowTitles(for app: NSRunningApplication) -> [BrowserWindowTitle] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        var focusedRef: AnyObject?
        let focusedWindow: AXUIElement?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() {
            focusedWindow = (focusedRef as! AXUIElement)
        } else {
            focusedWindow = nil
        }

        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            // No window list (or it timed out). The focused window alone is
            // still useful.
            guard let focusedWindow, let title = title(of: focusedWindow) else { return [] }
            return [BrowserWindowTitle(title: title, isFocused: true)]
        }

        return windows.prefix(maxWindowsPerApp).compactMap { window in
            guard let title = title(of: window) else { return nil }
            let isFocused = focusedWindow.map { CFEqual($0, window) } ?? false
            return BrowserWindowTitle(title: title, isFocused: isFocused)
        }
    }

    private static func title(of window: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
    }
}

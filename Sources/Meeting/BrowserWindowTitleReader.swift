// BrowserWindowTitleReader.swift
// Reads the window titles of the browsers that hold the mic, through the
// Accessibility permission Transcripted holds for paste-back. Feeds
// `BrowserCallEvidence.classify`.
//
// Privacy: titles are returned to the caller, classified in memory, and
// dropped. This file never logs, stores, or reports them. Without
// Accessibility (`AXIsProcessTrusted() == false`) it returns nothing and the
// detector falls back to its timing rules; it never asks for the permission.
//
// Only window titles are read (`kAXWindowsAttribute` + `kAXTitleAttribute` on
// the app element), never page content. The Accessibility round trips run on
// a background queue under one overall time budget, so a slow or hung browser
// can neither stall the main thread nor hold a read open for long.

import AppKit
import ApplicationServices

enum BrowserWindowTitleReader {
    /// Total time one read may spend across every browser app and window.
    /// Titles are a nice-to-have; running out just means fewer titles, and no
    /// titles means "unknown", which falls back to the timing rules.
    static let readBudget: TimeInterval = 0.3
    /// Upper bound on any single AX round trip, inside the overall budget.
    private static let maxMessagingTimeout: TimeInterval = 0.1
    /// Enough for any real window layout; stops a pathological app from
    /// making us walk hundreds of windows.
    private static let maxWindowsPerApp = 16

    private static let readQueue = DispatchQueue(
        label: "com.transcripted.browser-window-titles",
        qos: .utility
    )

    /// Titles of every window of the running browser apps in `families`
    /// (bundle-family prefixes from `MeetingPromptProvider.browserBundleIDPrefixes`).
    @MainActor
    static func titles(forBrowserFamilies families: Set<String>) async -> [BrowserWindowTitle] {
        guard !families.isEmpty, AXIsProcessTrusted() else { return [] }

        let appFamilies = Set(families.map(MeetingPromptProvider.browserAppFamily(forBundleFamily:)))
        // Bundle IDs are read off the main thread: that read can block on
        // LaunchServices. The frontmost pid is captured here too: a Helium
        // Meet shortcut and the main browser share one mic helper, so both
        // match the family, and only the app the user is in is "focused".
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pids: [pid_t] = await RunningApplicationsReader.applications().compactMap { app in
            guard app.isRegularApp,
                  let bundleID = app.bundleIdentifier,
                  appFamilies.contains(where: { bundleID.matchesBundleFamily($0) }) else { return nil }
            return app.processIdentifier
        }
        let ordered = readingOrder(pids: pids, frontmostPID: frontmostPID)
        guard !ordered.isEmpty else { return [] }

        return await withCheckedContinuation { continuation in
            readQueue.async {
                let deadline = Date().addingTimeInterval(readBudget)
                var titles: [BrowserWindowTitle] = []
                for pid in ordered {
                    guard Date() < deadline else { break }
                    titles.append(contentsOf: windowTitles(
                        forPID: pid,
                        deadline: deadline,
                        userFocused: isUserFocused(appPID: pid, frontmostPID: frontmostPID)
                    ))
                }
                continuation.resume(returning: titles)
            }
        }
    }

    /// The frontmost app first. The title read has one short budget for every
    /// app in the family. A Meet shortcut beside a busy main browser would
    /// otherwise lose its windows to that budget.
    static func readingOrder(pids: [pid_t], frontmostPID: pid_t?) -> [pid_t] {
        guard let frontmostPID, let index = pids.firstIndex(of: frontmostPID) else { return pids }
        var ordered = pids
        ordered.remove(at: index)
        ordered.insert(frontmostPID, at: 0)
        return ordered
    }

    /// True only for the app the user is looking at. Each browser app has its
    /// own key window; that is not the focused window unless the app is frontmost.
    static func isUserFocused(appPID: pid_t, frontmostPID: pid_t?) -> Bool {
        guard let frontmostPID else { return false }
        return appPID == frontmostPID
    }

    private static func windowTitles(forPID pid: pid_t, deadline: Date, userFocused: Bool) -> [BrowserWindowTitle] {
        let appElement = AXUIElementCreateApplication(pid)

        var focusedWindow: AXUIElement?
        if setTimeout(on: appElement, deadline: deadline) {
            var focusedRef: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
               let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() {
                focusedWindow = (focusedRef as! AXUIElement)
            }
        }

        var windowsRef: AnyObject?
        guard setTimeout(on: appElement, deadline: deadline),
              AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            // No window list (or no time left for it). The focused window
            // alone is still useful.
            guard let focusedWindow, let title = title(of: focusedWindow, deadline: deadline) else { return [] }
            return [BrowserWindowTitle(title: title, isFocused: userFocused)]
        }

        var titles: [BrowserWindowTitle] = []
        for window in windows.prefix(maxWindowsPerApp) {
            guard Date() < deadline else { break }
            guard let title = title(of: window, deadline: deadline) else { continue }
            let isKeyWindow = focusedWindow.map { CFEqual($0, window) } ?? false
            titles.append(BrowserWindowTitle(title: title, isFocused: userFocused && isKeyWindow))
        }
        return titles
    }

    private static func title(of window: AXUIElement, deadline: Date) -> String? {
        guard setTimeout(on: window, deadline: deadline) else { return nil }
        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
    }

    /// Bounds the next AX round trip on `element` by what is left of the
    /// budget. Returns false when the budget is spent.
    /// The call a running Chromium app shortcut is for, or `nil`. Reads
    /// `CrAppModeShortcutURL` and drops it; only the provider enum leaves.
    static func callShortcutProvider(forBundleID bundleID: String) async -> MeetingPromptProvider? {
        let url = await Task.detached(priority: .utility) {
            shortcutURL(forBundleID: bundleID)
        }.value
        guard let url else { return nil }
        return BrowserCallEvidence.callShortcutProvider(forURL: url)
    }

    /// Off the main actor: `bundleURL` can block on LaunchServices, and the
    /// URL itself is never logged.
    private static func shortcutURL(forBundleID bundleID: String) -> String? {
        guard let bundleURL = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL else {
            return nil
        }
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let url = plist["CrAppModeShortcutURL"] as? String,
              !url.isEmpty else { return nil }
        return url
    }

    private static func setTimeout(on element: AXUIElement, deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.005 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(min(remaining, maxMessagingTimeout)))
        return true
    }
}

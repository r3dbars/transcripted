// ScreenCapture.swift
// Captures the frontmost window as a PNG image

import AppKit
import CoreGraphics

struct ScreenCapture {

    /// Capture the frontmost window of a given app as PNG data
    static func captureFrontmostWindow(of app: NSRunningApplication) -> Data? {
        let pid = app.processIdentifier

        // Get all on-screen windows for this app
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Find the frontmost window belonging to this app's PID
        let appWindows = windowList.filter { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int else {
                return false
            }
            return ownerPID == pid && layer == 0  // layer 0 = normal windows
        }

        guard let targetWindow = appWindows.first,
              let windowID = targetWindow[kCGWindowNumber as String] as? CGWindowID else {
            return nil
        }

        // Capture just this window
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return nil
        }

        // Convert to PNG data
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:])
    }
}

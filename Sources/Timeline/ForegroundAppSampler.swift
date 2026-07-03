// ForegroundAppSampler.swift
// Frontmost app and best-effort window-title metadata for local timeline capture.

import AppKit
import CoreGraphics
import Foundation

struct ForegroundAppSnapshot: Equatable {
    let bundleIdentifier: String?
    let appName: String?
    let windowTitle: String?
}

final class ForegroundAppSampler {
    private let workspace: NSWorkspace
    private let windowInfoProvider: () -> [[String: Any]]

    init(
        workspace: NSWorkspace = .shared,
        windowInfoProvider: @escaping () -> [[String: Any]] = ForegroundAppSampler.onScreenWindowInfo
    ) {
        self.workspace = workspace
        self.windowInfoProvider = windowInfoProvider
    }

    func currentSnapshot() -> ForegroundAppSnapshot {
        let app = workspace.frontmostApplication
        let title = app.flatMap { Self.windowTitle(for: $0, windows: windowInfoProvider()) }
        return ForegroundAppSnapshot(
            bundleIdentifier: app?.bundleIdentifier,
            appName: app?.localizedName,
            windowTitle: title
        )
    }

    static func windowTitle(for app: NSRunningApplication, windows: [[String: Any]]) -> String? {
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier else {
                continue
            }

            if let layer = window[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }

            if let title = window[kCGWindowName as String] as? String,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
        }

        return nil
    }

    static func onScreenWindowInfo() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return rawWindows
    }
}

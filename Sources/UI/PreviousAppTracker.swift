// PreviousAppTracker.swift
// Tracks which app the user was in before switching to Draft

import AppKit

@MainActor
class PreviousAppTracker: ObservableObject {
    @Published var previousApp: NSRunningApplication?
    private let myBundleID = Bundle.main.bundleIdentifier ?? "com.justinbetker.draft"

    init() {
        // When any app loses focus and it's not Draft, remember it
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != self?.myBundleID {
                Task { @MainActor in
                    self?.previousApp = app
                }
            }
        }
    }
}

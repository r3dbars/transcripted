// OnboardingWindowController.swift
// Standalone onboarding window — 5-step guided walkthrough for new users.
// Separate from the menubar popover so onboarding gets full attention.

import SwiftUI
import AppKit

@MainActor
class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    weak var sessionController: DraftSessionController?
    weak var overlayController: FloatingOverlayController?
    weak var appState: DraftAppState?

    func show() {
        guard window == nil else { return }
        guard let sessionController = sessionController,
              let overlayController = overlayController,
              let appState = appState else { return }

        let onboardingView = OnboardingView(
            sessionController: sessionController,
            overlayController: overlayController,
            appState: appState,
            onComplete: { [weak self] in
                self?.complete()
            },
            adjustWindow: { [weak self] floating in
                self?.setFloating(floating)
            }
        )

        let hostingController = NSHostingController(rootView: onboardingView)
        let win = NSWindow(contentViewController: hostingController)
        win.title = "Welcome to Draft"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 640, height: 560))
        win.level = .floating
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    func close() {
        window?.close()
        window = nil
    }

    /// Lower window to normal level during try-it steps so the user's messaging apps
    /// can be frontmost (and the screenshot captures the right app). Raise back to
    /// floating + bring to front when the step completes.
    private func setFloating(_ floating: Bool) {
        guard let window = window else { return }
        if floating {
            window.level = .floating
            window.orderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.level = .normal
        }
    }

    private func complete() {
        markOnboardingComplete()
        close()
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        // User clicked the red X — mark complete so it doesn't reappear
        Task { @MainActor [weak self] in
            self?.markOnboardingComplete()
            self?.window = nil
        }
    }

    private func markOnboardingComplete() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "onboarding-completed")
        defaults.set(true, forKey: "permissionsOnboardingCompleted")
        appState?.styleEngine.completeOnboarding()
    }
}

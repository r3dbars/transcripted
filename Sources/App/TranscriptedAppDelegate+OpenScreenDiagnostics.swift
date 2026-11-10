import AppKit

/// Feeds the `open_screen` tag on crash and hang reports
/// (`OpenScreenDiagnostics`). Main-thread hangs land mostly while the app is
/// idle with no app frames on the stack, so the open window is the one clue
/// they can carry. Reads only window and popover visibility and the Settings
/// page id, on main.
///
/// It finds the Settings and onboarding windows through `NSApp.windows`
/// rather than the delegate's lazy controllers, so reading the open screen
/// never builds a window that wasn't opened.
extension TranscriptedAppDelegate {
    @MainActor
    private enum OpenScreenObservers {
        static var tokens: [NSObjectProtocol] = []
    }

    /// The front-most Transcripted screen, as `OpenScreenDiagnostics` names it.
    /// A minimized or closed window doesn't count.
    func currentOpenScreenForDiagnostics() -> String {
        var onboardingVisible = false
        var settingsPage: String?
        for window in NSApp.windows where window.isVisible {
            switch window.windowController {
            case is TranscriptedOnboardingWindowController:
                onboardingVisible = true
            case let settings as TranscriptedSettingsWindowController:
                settingsPage = settings.automationScreenName()
            default:
                break
            }
        }
        return OpenScreenDiagnostics.resolve(
            onboardingVisible: onboardingVisible,
            menuBarShown: popover?.isShown == true,
            settingsPage: settingsPage
        )
    }

    /// Call once at launch. The heartbeat also re-reads the provider every
    /// minute, so a missed change is caught up then.
    func startOpenScreenDiagnostics() {
        guard OpenScreenObservers.tokens.isEmpty else { return }
        appState.runtimeDiagnostics.setOpenScreenProvider { [weak self] in
            self?.currentOpenScreenForDiagnostics() ?? OpenScreenDiagnostics.none
        }

        // Close notifications arrive before the window is gone and before
        // the Settings controller marks itself closed, so read on a later turn.
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSPopover.didShowNotification,
            NSPopover.didCloseNotification,
        ]
        OpenScreenObservers.tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { self?.openScreenMayHaveChanged(window) }
            }
        }
    }

    private func openScreenMayHaveChanged(_ window: NSWindow?) {
        // Settings page changes don't post a window notification, so the
        // Settings window reports them itself once it has been shown.
        if let settings = window?.windowController as? TranscriptedSettingsWindowController {
            settings.setPageChangeHandler { [weak self] in
                self?.appState.runtimeDiagnostics.refreshOpenScreen()
            }
        }
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.appState.runtimeDiagnostics.refreshOpenScreen() }
        }
    }
}

#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import AppKit
import Foundation

/// Owns Writing's optional window observation and the single pause-expiry
/// wakeup. Stopping observation leaves the loaded helper/cache available.
@MainActor
final class WritingFrontWindowObserver {
    private let prewarmer: ScaffoldPrewarmer
    private let screenCaptureService: ScreenCaptureService
    private let pauseWakeup = WritingPauseWakeup()
    private var autocompleteActive = false
    private var appObserver: NSObjectProtocol?
    private var poller: WritingFrontWindowPoller?

    init(prewarmer: ScaffoldPrewarmer, screenCaptureService: ScreenCaptureService) {
        self.prewarmer = prewarmer
        self.screenCaptureService = screenCaptureService
    }

    func update(autocompleteActive: Bool) {
        self.autocompleteActive = autocompleteActive
        let settings = WritingController.settings()
        let pausedUntil = settings.pausedUntil
        let plan = WritingFrontWindowWatch.plan(
            running: true,
            autocompleteActive: autocompleteActive,
            screenMemoryEnabled: settings.screenMemoryEnabled,
            paused: pausedUntil != nil
        )
        pauseWakeup.schedule(until: autocompleteActive ? pausedUntil : nil) { [weak self] in
            guard let self else { return }
            self.update(autocompleteActive: self.autocompleteActive)
        }
        prewarmer.setEnabled(plan.observesAppActivation)
        if plan.observesAppActivation {
            // Refresh before warming on resume: the user may have switched
            // apps while observation was suspended.
            prewarmer.noteFrontmostApp(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            startObservingAppActivation()
        } else {
            stopObservingAppActivation()
        }
        if plan.pollsFrontWindow {
            if poller == nil {
                poller = WritingFrontWindowPoller { [weak self] identity in
                    let target = identity.map { WritingController.typingTarget(from: $0, sessionIdentifier: "") }
                    self?.noteWindowChanged(target: target)
                }
            }
        } else {
            poller?.stop()
            poller = nil
        }
    }

    func stop() {
        update(autocompleteActive: false)
    }

    isolated deinit { stop() }

    private func startObservingAppActivation() {
        guard appObserver == nil else { return }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.appObserver != nil else { return }
                let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self.prewarmer.noteFrontmostApp(bundleIdentifier: activated?.bundleIdentifier)
                guard WritingController.settings().screenMemoryEnabled else { return }
                self.noteWindowChanged(target: WritingController.currentTypingTarget(sessionIdentifier: ""))
            }
        }
    }

    private func stopObservingAppActivation() {
        guard let appObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(appObserver)
        self.appObserver = nil
    }

    private func noteWindowChanged(target: TypingTargetIdentity?) {
        guard autocompleteActive, WritingController.settings().pausedUntil == nil,
              WritingController.preferences().allows(appBundleIdentifier: target?.bundleIdentifier) else { return }
        Task { await screenCaptureService.noteWindowChanged(target: target) }
    }
}

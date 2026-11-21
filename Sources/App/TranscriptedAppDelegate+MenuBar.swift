// TranscriptedAppDelegate+MenuBar.swift
// Status item badge, popover, onboarding, settings window and Dock policy wiring

import SwiftUI
import AppKit
import AVFoundation
import Carbon
import Combine
import Darwin
import TranscriptedCore
import UniformTypeIdentifiers

extension TranscriptedAppDelegate {
    /// The update used to be an orange dot pinned on the icon, the one color
    /// in a one-color glyph. It is now the glyph's own template dot
    /// (`MenuBarGlyph.attention`), so the old badge view stays hidden.
    func installStatusItemUpdateBadge(on button: NSStatusBarButton) {
        statusItemUpdateBadge.isHidden = true
    }

    func bindStatusItemUpdateBadge() {
        // The automatic-download setting decides whether an available update
        // needs a click, so the dot follows both publishers.
        appState.sparkleUpdater.$updateStatus
            .combineLatest(appState.sparkleUpdater.$automaticUpdateSettings)
            .receive(on: RunLoop.main)
            .sink { [weak self] status, settings in
                self?.updateStatusItemBadge(for: status, settings: settings)
            }
            .store(in: &statusItemSubscriptions)
        updateStatusItemBadge(
            for: appState.sparkleUpdater.updateStatus,
            settings: appState.sparkleUpdater.automaticUpdateSettings
        )
    }

    /// What `refreshStatusItemPresentation` writes: capture, a transcript
    /// being made, and anything that needs a click.
    func applyStatusItemPresentation(to button: NSStatusBarButton) {
        let state = statusItemWorkAndAttention()
        StatusItemPresentation.apply(
            to: button,
            meetingRecording: statusItemMeetingRecording,
            dictating: statusItemDictationRecording,
            transcribing: state.transcribing,
            attention: state.attention,
            updateTooltip: statusItemUpdateTooltip
        )
    }

    /// Whether a meeting transcript is being made, and whether something
    /// needs a click, read live for `refreshStatusItemPresentation`. A key
    /// that can't work (Accessibility off) outranks an update.
    func statusItemWorkAndAttention() -> (transcribing: Bool, attention: StatusItemPresentation.Attention?) {
        var transcribing = false
        if #available(macOS 14.0, *), case .transcribing = appState.meetingSession.state {
            transcribing = true
        }
        let attention: StatusItemPresentation.Attention?
        if appState.contextCapture.hotkeyError == ContextCaptureEngine.accessibilityPermissionErrorMessage {
            attention = .shortcutsNeedAccessibility
        } else if SparkleUpdaterController.updateNeedsUserAction(
            status: appState.sparkleUpdater.updateStatus,
            settings: appState.sparkleUpdater.automaticUpdateSettings
        ) {
            attention = .updateNeedsClick
        } else {
            attention = nil
        }
        return (transcribing, attention)
    }

    /// Keeps the status-item glyph in sync with active capture so the menu bar
    /// itself answers "am I recording?" without opening the popover.
    func bindStatusItemRecordingIndicator() {
        appState.sttRouter.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                guard let self, self.statusItemDictationRecording != isRecording else { return }
                self.statusItemDictationRecording = isRecording
                self.refreshStatusItemPresentation()
            }
            .store(in: &statusItemSubscriptions)

        if #available(macOS 14.0, *) {
            // MeetingSessionController.isRecording is computed from `state`
            // (2026-08 state-collapse audit) instead of a separate
            // @Published mirror, so Combine subscribers derive their own
            // publisher from `$state` instead of subscribing to `$isRecording`.
            appState.meetingSession.$state
                .map { MeetingSessionStateMachine.isSteadyStateRecording($0) }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isRecording in
                    guard let self, self.statusItemMeetingRecording != isRecording else { return }
                    self.statusItemMeetingRecording = isRecording
                    self.refreshStatusItemPresentation()
                }
                .store(in: &statusItemSubscriptions)

            // The working ring while a meeting transcript is being made.
            appState.meetingSession.$state
                .map { state -> Bool in
                    if case .transcribing = state { return true }
                    return false
                }
                .removeDuplicates()
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshStatusItemPresentation() }
                .store(in: &statusItemSubscriptions)
        }

        // The attention dot while the keys can't work without Accessibility.
        appState.contextCapture.$hotkeyError
            .map { $0 == ContextCaptureEngine.accessibilityPermissionErrorMessage }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatusItemPresentation() }
            .store(in: &statusItemSubscriptions)
    }

    /// The attention dot shows as soon as an update needs a click: a
    /// downloaded update waiting for a restart, or an update Sparkle will not
    /// download on its own. The tooltip uses the popover's update words.
    private func updateStatusItemBadge(
        for status: SparkleUpdaterController.UpdateStatus,
        settings: SparkleUpdaterController.AutomaticUpdateSettings
    ) {
        let needsAction = SparkleUpdaterController.updateNeedsUserAction(status: status, settings: settings)
        statusItemUpdateTooltip = needsAction ? UpdateStatusWords.statusItemNote(for: .init(status.state)) : nil
        refreshStatusItemPresentation()
    }

    func showSettingsWindow(
        page: TranscriptedSettingsPage = .today,
        source: String = "unknown"
    ) {
        settingsWindowController.present(page: page, source: source)
    }

    func makeOnboardingView() -> PermissionsOnboardingView {
        PermissionsOnboardingView(
            sttRouter: appState.sttRouter,
            onComplete: { [weak self] in
                self?.finishOnboarding()
            }
        )
    }

    func presentInitialOnboardingIfNeeded() {
        guard !PermissionsOnboardingPreferences.hasCompleted(), !hasPresentedInitialOnboarding else { return }
        hasPresentedInitialOnboarding = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.onboardingWindowController.isVisible, !PermissionsOnboardingPreferences.hasCompleted() else { return }
            self.onboardingWindowController.present(entrypoint: "initial_launch")
        }
    }

    private func finishOnboarding() {
        PermissionsOnboardingPreferences.markCompleted()
        CrashReporter.applySessionTrackingPreference()
        // Meeting detection only works while the app runs; register the login
        // item by default now that onboarding gives the macOS notice context.
        // One-time, and an explicit Settings choice always wins. The XPC calls
        // run off the main thread so Finish never waits on them.
        Task { @MainActor in
            if let message = await LaunchAtLoginController.applyDefaultEnableIfNeeded(onboardingCompleted: true) {
                EventReporter.shared.capture(level: .warning, engine: "app", event: "login_item_default_enable_failed",
                    message: message)
            }
        }
        appState.recoverHotkeysAfterPermissionChange()
        onboardingWindowController.dismiss()
        closePopover()
        // Setup ends on Today in the main window, not the popover: the person
        // already dictated in setup, and Today is where they land from now on.
        showSettingsWindow(page: .today, source: "onboarding_completed")
    }

    func showMainPopover(
        relativeTo button: NSStatusBarButton,
        popover: NSPopover,
        entrypoint: String = "status_item"
    ) {
        _ = resolvedSourceApp()
        menuPanelController.refresh()
        popover.contentViewController = menuPanelController
        popover.contentSize = menuPanelController.preferredContentSize
        if menuPopoverPresentation.show(popover, relativeTo: button) {
            trackMenuBarOpened(entrypoint: entrypoint)
        }
    }

    func closePopover() {
        menuPanelController.prepareForClose()
        if let popover { menuPopoverPresentation.close(popover) }
        if popover?.contentViewController !== menuPanelController {
            popover?.contentViewController = nil
        }
    }

    private func trackMenuBarOpened(entrypoint: String) {
        let modelState = appState.sttRouter.modelDownloadState.diagnosticName

        let updateState: String
        switch appState.sparkleUpdater.updateStatus.state {
        case .unknown:
            updateState = "unknown"
        case .readyToCheck:
            updateState = "ready"
        case .checking:
            updateState = "checking"
        case .noUpdateAvailable:
            updateState = "up_to_date"
        case .updateAvailable:
            updateState = "available"
        case .downloading:
            updateState = "downloading"
        case .readyToInstall:
            updateState = "ready_to_install"
        }

        AnalyticsReporter.track(
            "menu_bar_opened",
            properties: [
                "dictation_ready": appState.sttRouter.isModelLoaded ? "true" : "false",
                "entrypoint": entrypoint,
                "meeting_recording_ready": TranscriptedPermissionAccess.isGranted(.systemAudioRecording) ? "true" : "false",
                "model_state": modelState,
                "update_state": updateState,
            ]
        )
    }

    func trackOnboardingShown(entrypoint: String) {
        AnalyticsReporter.track(
            "onboarding_shown",
            properties: [
                "analytics_available": AnalyticsReporter.isAvailable ? "true" : "false",
                "crash_reporting_available": CrashReporter.isAvailable ? "true" : "false",
                "entrypoint": entrypoint,
                "has_target": lastExternalApplication == nil ? "false" : "true",
                "meeting_recording_ready": TranscriptedPermissionAccess.isGranted(.systemAudioRecording) ? "true" : "false",
                "mic_status": TranscriptedPermissionAccess.microphoneAuthorizationStatus().diagnosticName,
                "model_state": appState.sttRouter.modelDownloadState.diagnosticName,
                "pasteback_status": TranscriptedPermissionAccess.isGranted(.accessibility) ? "granted" : "not_granted",
            ]
        )
    }

    func meetingPromptTelemetryReadiness() -> MeetingPromptTelemetryReadiness {
        MeetingPromptTelemetryReadiness(
            microphoneGranted: TranscriptedPermissionAccess.isGranted(.microphone),
            systemAudioRecordingGranted: TranscriptedPermissionAccess.isGranted(.systemAudioRecording),
            meetingRecordingActive: appState.meetingSession.isRecording,
            dictationRecordingActive: appState.sttRouter.isRecording
        )
    }

    func consumeMeetingPromptShownElapsedSeconds(candidateID: String) -> TimeInterval? {
        guard let shownAt = meetingPromptShownAtByCandidateID.removeValue(forKey: candidateID) else {
            return nil
        }
        return Date().timeIntervalSince(shownAt)
    }

    func resolvedSourceApp() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = frontmost
            return frontmost
        }

        if let lastExternalApplication,
           lastExternalApplication.bundleIdentifier != Bundle.main.bundleIdentifier {
            return lastExternalApplication
        }

        return nil
    }

    /// Subscribe to the Dock preference plus meeting and dictation
    /// recording flags so the activation-policy controller can keep the
    /// app visible when users want a Dock icon or when active capture
    /// needs force-quit visibility.
    func wireActivationPolicy(controller: ActivationPolicyController) {
        NotificationCenter.default.publisher(for: .dockVisibilityPreferencesDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak controller] _ in
                controller?.setShowInDock(DockVisibilityPreferences.isVisible())
            }
            .store(in: &activationPolicySubscriptions)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak controller] _ in
                controller?.reapplyCurrentPolicy()
            }
            .store(in: &activationPolicySubscriptions)

        // Dictation: STTRouter publishes its own isRecording flag.
        appState.sttRouter.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak controller] isRecording in
                controller?.setDictationRecording(isRecording)
            }
            .store(in: &activationPolicySubscriptions)

        // Meeting: the @MainActor MeetingSessionController owns the flag.
        // Only available on macOS 14+, matching where MeetingSession lives.
        // isRecording is computed from `state` (2026-08 state-collapse
        // audit), so this derives its own publisher from `$state` instead of
        // subscribing to a removed `$isRecording`. This is the safety
        // -relevant force-quit-visibility path (see ActivationPolicyController's
        // header comment: promotes to `.regular` "so it stays visible in
        // Cmd+Option+Esc for recovery"), so it uses the broad
        // isCaptureSessionActive mapping — starting+recording+stopping, the
        // same signal shouldConfirmQuitForActiveCapture uses — not the
        // narrow steady-state-only isRecording. With Show in Dock off, the
        // narrow mapping would let the app vanish from the force-quit dialog
        // for the ~12s mic-engage window and the up-to-~120s stop/cancel
        // teardown window, exactly while a stuck capture is most likely to
        // need force-quit recovery.
        if #available(macOS 14.0, *) {
            appState.meetingSession.$state
                .map { MeetingSessionStateMachine.isCaptureSessionActive($0) }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak controller] isCaptureActive in
                    controller?.setMeetingRecording(isCaptureActive)
                }
                .store(in: &activationPolicySubscriptions)
        }
    }
}

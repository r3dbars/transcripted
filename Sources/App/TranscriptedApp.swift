// TranscriptedApp.swift
// Menubar app for local dictation + meeting transcription

import SwiftUI
import AppKit
import AVFoundation
import Carbon
import Combine
import Darwin
import TranscriptedCore
import UniformTypeIdentifiers

@main
struct TranscriptedApp: App {
    @NSApplicationDelegateAdaptor(TranscriptedAppDelegate.self) var appDelegate

    init() {
        // Set this before app startup creates logs, scratch files, or atomic-write
        // temp files so new app-owned files default to owner-only permissions.
        umask(0o077)
    }

    var body: some Scene {
        // The app owns a richer AppKit Settings window. Keep this scene as a
        // harmless recovery surface for any system path that opens the SwiftUI
        // Settings scene directly; the normal Settings command is replaced in
        // TranscriptedMenuCommands and routes to the real window.
        Settings {
            TranscriptedSettingsFallbackView {
                appDelegate.menuOpenSettings()
            }
        }
        .commands {
            TranscriptedMenuCommands(appDelegate: appDelegate)
        }
    }
}

private struct TranscriptedSettingsFallbackView: View {
    @Environment(\.dismiss) private var dismiss
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Transcripted Settings")
                .font(.headline)
            Text("Open the full Transcripted window to change settings.")
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                dismiss()
                openSettings()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("transcripted.settings.fallback.open")
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(width: 360, height: 180)
    }
}

// MARK: - App Delegate

@MainActor
class TranscriptedAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    let menuPopoverPresentation = MenuBarPopoverPresentation()
    var lastExternalApplication: NSRunningApplication?
    var hasPresentedInitialOnboarding = false
    let statusItemUpdateBadge = NSView(frame: .zero)
    var statusItemSubscriptions: Set<AnyCancellable> = []
    var statusItemMeetingRecording = false
    var statusItemDictationRecording = false
    var statusItemUpdateTooltip: String?
    let settingsTextPaster = ClipboardRestoringTextPaster()
    var pendingAudioImports = AudioImportQueue()
    var audioImportPumpTask: Task<Void, Never>?
    var audioImportCaptureEndSubscription: AnyCancellable?
    /// Bumped by Cancel so a hand-off that was already in flight doesn't put
    /// its file back in the queue afterwards.
    var audioImportGeneration = 0
    private lazy var settingsActions = TranscriptedSettingsActions(
        startDictation: { [weak self] in self?.startDictationFromSettings() },
        startMeeting: { [weak self] in self?.startMeetingFromSettings() },
        importAudioFile: { [weak self] in self?.importAudioFileFromSettings() },
        importAudioFiles: { [weak self] urls in self?.importAudioFiles(urls) },
        cancelPendingAudioImports: { [weak self] in self?.cancelPendingAudioImports() },
        sendFeedback: { [weak self] in
            guard let self else { return }
            let appState = self.appState
            Task { @MainActor in
                await TranscriptedSupportActions.sendFeedback(appState: appState)
            }
        },
        sendDiagnosticEvent: { [weak self] in
            guard let self else { return nil }
            return await TranscriptedSupportActions.sendDiagnosticEvent(appState: self.appState)
        }
    )
    lazy var settingsWindowController = TranscriptedSettingsWindowController(
        appState: appState,
        actions: settingsActions
    )
    lazy var onboardingWindowController = TranscriptedOnboardingWindowController(
        makeView: { [unowned self] in self.makeOnboardingView() },
        onPresent: { [weak self] entrypoint in
            self?.trackOnboardingShown(entrypoint: entrypoint)
        }
    )
    lazy var menuPanelController = MenuBarPanelController(
        appState: appState,
        preferredSourceAppProvider: { [weak self] in self?.lastExternalApplication },
        openSettingsWindow: { [weak self] page in self?.showSettingsWindow(page: page, source: "menu_bar") },
        dismissPopover: { [weak self] in self?.closePopover() }
    )

    private let singleInstanceGuard = SingleInstanceGuard()
    private var singleInstanceReopenObserver: NSObjectProtocol?
    private var duplicateInstanceShouldTerminateImmediately = false

    let appState = TranscriptedAppState()
    let overlayController = FloatingOverlayController()
    /// Carries dictation, meetings and the call prompt.
    let notchIsland = NotchIslandController()
    let sessionController = DictationSessionController()
    /// Second non-activating panel for meeting mode (Lane C). Distinct from
    /// the dictation overlay so regressions to one can't break the other.
    @available(macOS 14.0, *)
    lazy var meetingOverlayController = MeetingOverlayController()
    @available(macOS 14.0, *)
    lazy var capturePillController = CapturePillController()
    @available(macOS 14.0, *)
    lazy var meetingPromptDetector = MeetingPromptDetector(learnedBackoffDefaults: .standard)
    @available(macOS 14.0, *)
    lazy var micActivityMonitor = MicActivityMonitor()
    @available(macOS 14.0, *)
    lazy var cameraActivityMonitor = CameraActivityMonitor()
    @available(macOS 14.0, *)
    private var meetingPromptRecordAction: MeetingPromptRecordAction?
    private var meetingPromptRecordInFlight = false
    private var meetingPromptSubscriptions: Set<AnyCancellable> = []
    var meetingPromptShownAtByCandidateID: [String: Date] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    var micPreferenceObserver: NSObjectProtocol?
    var lastAppliedAutoCallDetectionEnabled: Bool?
    private var terminationCleanupStarted = false
    private var terminationCleanupFinished = false
    var pendingTerminationReplyCount = 0

    /// Keeps NSApp in sync with the Dock visibility setting and promotes
    /// the app to `.regular` during active recording for force-quit
    /// recovery. Initialized in `applicationDidFinishLaunching` after
    /// AppKit is ready.
    private var activationPolicyController: ActivationPolicyController?
    var activationPolicySubscriptions: Set<AnyCancellable> = []
    private lazy var persistentDictationInputController = PersistentDictationInputController(
        isDictationActive: { [weak self] in
            self?.sessionController.isDictating == true
        },
        isMeetingCaptureActive: { [weak self] in
            guard #available(macOS 14.0, *), let self else { return false }
            return self.appState.meetingSession.isCaptureSessionActive
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        if DictationStopBenchmarkRunner.runFromEnvironmentIfRequested() {
            return
        }

        guard acquireSingleInstanceLock() else { return }
        // Read before anything else runs: the launch Apple event is only
        // current while this delegate call is handling it.
        let launchedAsLoginItem = Self.wasLaunchedAsLoginItem()

        // Crash reporting
        CrashReporter.setup()
        if PermissionsOnboardingPreferences.hasCompleted() {
            CrashReporter.applySessionTrackingPreference()
        }
        // Before any recording reads the mode: a Boost accepted before 1.1.63
        // was saved for every meeting and made call audio quieter.
        if MicrophoneProcessingPreferences.migrateBoostedVoiceProcessingIfNeeded() {
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "mic_processing_boost_migrated",
                message: "Saved Apple voice processing moved back to software autogain"
            )
        }
        persistentDictationInputController.start()
        // Drop expired dictionary-fix backups and any whose meeting is gone.
        Task.detached(priority: .background) {
            DictionaryPastMeetingBackupStore.default().prune(meetingsDirectory: MeetingStoragePaths.transcriptsFolder)
        }

        let activationController = ActivationPolicyController(
            actualPolicy: { NSApp.activationPolicy() }
        )
        activationPolicyController = activationController
        wireActivationPolicy(controller: activationController)
        DispatchQueue.main.async { [weak activationController] in
            activationController?.reapplyCurrentPolicy()
        }

        // Wire session controller
        sessionController.appState = appState
        sessionController.overlayController = overlayController
        sessionController.onTranscribeSavedAudio = { [weak self] url in
            self?.importAudioFiles([url])
        }
        appState.contextCapture.sessionController = sessionController

        // Set up the floating overlay panel (pure AppKit — no NSHostingView)
        overlayController.setup(sttRouter: appState.sttRouter)
        overlayController.island = notchIsland
        notchIsland.lastDictationTextProvider = { [weak self] in
            self?.sessionController.lastCompletedText
        }
        notchIsland.onPasteLastDictation = { [weak self] in
            self?.pasteLastDictationFromSettings()
        }
        notchIsland.prewarm()
        AppLaunchSteps.runAfterOverlaySetup(dictation: sessionController)

        // Meeting overlay + hotkey + speaker naming — Lane C wiring.
        if #available(macOS 14.0, *) {
            let meetingSession = appState.meetingSession
            meetingSession.calendarSuggestedTitleProvider = { [weak self] in
                self?.meetingPromptDetector.currentSuggestedTranscriptTitle()
            }
            meetingPromptDetector.shouldSkipPromptEvaluation = { [weak self] in
                guard let self else { return false }
                return !MeetingPromptSessionPromptState(
                    self.appState.meetingSession.state
                ).allowsDetectedMeetingPrompt
            }
            meetingOverlayController.setup(meetingSession: meetingSession)
            meetingOverlayController.island = notchIsland
            capturePillController.island = notchIsland
            // With the Notch island, macOS's own allow box comes up at once the
            // first time. After a denial the meeting starts on the mic and the
            // island asks about call audio while it records, every meeting:
            // recording both sides is the point, so mic only is never
            // remembered as a choice.
            meetingSession.systemAudioAccessAsksWhileRecording = { true }
            // The session raises the island's ask from the start's outcome
            // (so a first-time macOS Don't Allow asks too); the prompter only
            // answers the question.
            meetingSession.systemAudioAccessPrompter = { copy in
                if copy == .notYetAllowed { return .turnOn }
                return .askWhileRecording
            }
            let promptRecordAction = MeetingPromptRecordAction(
                onStartRequested: { [weak self] in
                    self?.meetingPromptRecordInFlight = true
                    self?.meetingOverlayController.showDetectedMeetingStartInProgress()
                },
                startRecording: { [weak self] candidate, promptTelemetryProperties in
                    guard let self else { return false }
                    return await self.appState.meetingSession.startRecording(
                        trigger: .detectedPrompt,
                        suggestedTitle: candidate.suggestedTranscriptTitle,
                        promptTelemetryProperties: promptTelemetryProperties
                    )
                },
                onCompleted: { [weak self] candidate, started in
                    self?.meetingPromptRecordInFlight = false
                    guard started else { return }
                    self?.meetingPromptDetector.markAccepted(candidate: candidate)
                }
            )
            meetingPromptRecordAction = promptRecordAction
            let recordPrompt: (MeetingPromptDetector.Candidate) -> Void = { [weak self] candidate in
                guard let self else { return }
                // startRecording returns true early, without publishing a state
                // transition, when a meeting is already recording/starting/stopping.
                // Without this gate the overlay enters .preparing and never leaves
                // ("Starting meeting…", no timer, no stop button), the candidate is
                // marked accepted so it is never recorded, and both choice events
                // report a selection that could not start anything. Same gate the
                // detector already applies in shouldSkipPromptEvaluation above.
                guard MeetingPromptSessionPromptState(
                    self.appState.meetingSession.state
                ).allowsDetectedMeetingPrompt else { return }
                let readiness = self.meetingPromptTelemetryReadiness()
                let elapsedSeconds = self.consumeMeetingPromptShownElapsedSeconds(candidateID: candidate.id)
                let promptFunnelProperties = MeetingPromptTelemetry.funnelProperties(
                    for: candidate,
                    readiness: readiness
                )
                guard promptRecordAction.record(
                    candidate: candidate,
                    promptTelemetryProperties: promptFunnelProperties
                ) else { return }
                // Mark accepted when start begins, not only after
                // startRecording returns. evaluate() can run while models
                // load / .startingRecording, and would otherwise close the
                // detected-call session as unrecorded.
                self.meetingPromptDetector.markAccepted(candidate: candidate)
                MeetingPromptTelemetry.emit(
                    .record(
                        candidate,
                        elapsedSeconds: elapsedSeconds,
                        signals: self.meetingPromptDetector.currentSignalSnapshot()
                    ),
                    readiness: readiness
                )
            }
            let dismissPrompt: (MeetingPromptDetector.Candidate) -> Void = { [weak self] candidate in
                guard let self else { return }
                let readiness = self.meetingPromptTelemetryReadiness()
                let elapsedSeconds = self.consumeMeetingPromptShownElapsedSeconds(candidateID: candidate.id)
                let backoffDecision = self.meetingPromptDetector.dismiss(candidate: candidate)
                MeetingPromptTelemetry.emit(
                    .dismiss(
                        candidate,
                        elapsedSeconds: elapsedSeconds,
                        backoffKind: backoffDecision.kind,
                        signals: self.meetingPromptDetector.currentSignalSnapshot(),
                        dismissStreak: self.meetingPromptDetector.dismissStreak(for: candidate.provider)
                    ),
                    readiness: readiness
                )
            }
            let expirePrompt: (MeetingPromptDetector.Candidate) -> Void = { [weak self] candidate in
                guard let self else { return }
                let readiness = self.meetingPromptTelemetryReadiness()
                let elapsedSeconds = self.consumeMeetingPromptShownElapsedSeconds(candidateID: candidate.id)
                MeetingPromptTelemetry.emit(.expire(candidate, elapsedSeconds: elapsedSeconds), readiness: readiness)
                _ = self.meetingPromptDetector.expire(candidate: candidate)
            }
            let remindPrompt: (MeetingPromptDetector.Candidate) -> Void = { [weak self] candidate in
                guard let self else { return }
                let readiness = self.meetingPromptTelemetryReadiness()
                let elapsedSeconds = self.consumeMeetingPromptShownElapsedSeconds(candidateID: candidate.id)
                MeetingPromptTelemetry.emit(.remindLater(candidate, elapsedSeconds: elapsedSeconds), readiness: readiness)
                _ = self.meetingPromptDetector.remindSoon(candidate: candidate)
            }
            capturePillController.onRecord = recordPrompt
            capturePillController.onDismiss = dismissPrompt
            capturePillController.onExpired = expirePrompt
            capturePillController.onRemind = remindPrompt
            // One event per suppression (see MeetingPromptTelemetry.PromptAction).
            meetingPromptDetector.onPromptSuppressed = { [weak self] suppression in
                guard let self else { return }
                MeetingPromptTelemetry.emit(
                    .suppress(suppression, signals: self.meetingPromptDetector.currentSignalSnapshot()),
                    readiness: self.meetingPromptTelemetryReadiness()
                )
            }
            meetingPromptDetector.onPromptRequest = { [weak self] candidate in
                guard PermissionsOnboardingPreferences.hasCompleted() else { return false }
                guard let self else { return false }
                let promptTimeout = MeetingPromptHeuristics.promptTimeoutSeconds(
                    for: candidate.reason,
                    calendarDefault: 30
                )
                // Say it before Record: after a remembered Don't Allow, the
                // meeting records only this person's mic without asking.
                let callAudioOff = MeetingMicOnlyNoticePolicy.detectedCallPromptSaysMicOnly(
                    status: TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem(),
                    micOnlyRemembered: MeetingMicOnlyChoicePreference.isRemembered()
                )
                let presented = self.capturePillController.present(
                    candidate: candidate,
                    timeout: TimeInterval(promptTimeout),
                    detailOverride: callAudioOff ? MeetingMicOnlyNoticeCopy.detectedCallPromptDetail : nil
                )
                if presented {
                    self.meetingPromptShownAtByCandidateID[candidate.id] = Date()
                    MeetingPromptTelemetry.emit(
                        .shown(candidate, signals: self.meetingPromptDetector.currentSignalSnapshot()),
                        readiness: self.meetingPromptTelemetryReadiness()
                    )
                }
                return presented
            }
            // Capture-funnel denominator: one event per detected call at its
            // end, recorded or not, so capture rate is measured against calls
            // that actually happened instead of prompts that fired.
            meetingPromptDetector.onDetectedCallEnded = { summary in
                AnalyticsReporter.track(
                    "meeting_detected_call_ended",
                    properties: MeetingPromptTelemetry.properties(for: summary)
                )
            }
            // Post-call awareness nudge: a long detected call ended with no
            // recording (and no explicit decline). Policy gates live in the
            // detector; the preference gate and opt-out live here.
            meetingPromptDetector.onUnrecordedCallEnded = { [weak self] call in
                guard let self else { return }
                guard MissedCallNudgePreferences.isEnabled() else { return }
                let presented = self.meetingOverlayController.presentMissedCallNudge(call)
                if presented {
                    AnalyticsReporter.track(
                        "meeting_missed_call_nudge",
                        properties: [
                            "action": "shown",
                            "duration_bucket": MissedCallNudgePolicy.durationBucket(for: call.duration),
                            "provider": call.provider.rawValue,
                        ]
                    )
                }
            }
            meetingOverlayController.onOpenMeetings = { [weak self] transcriptURL in
                self?.settingsWindowController.revealMeeting(
                    transcriptURL: transcriptURL,
                    source: "meeting_overlay"
                )
            }
            meetingOverlayController.onMissedCallNudgeResolved = { outcome in
                if outcome == .disabled {
                    MissedCallNudgePreferences.setEnabled(false)
                }
                AnalyticsReporter.track(
                    "meeting_missed_call_nudge",
                    properties: ["action": outcome.rawValue]
                )
            }
            // Ad-hoc call detection: never prompt while we already hold the mic
            // (meeting recording or dictation), and feed mic-activity into the
            // same prompt pipeline. See docs/auto-call-detection-spec.md.
            meetingPromptDetector.isOwnCaptureActive = { [weak self] in
                guard let self else { return false }
                return self.appState.meetingSession.isCaptureSessionActive
                    || self.meetingPromptRecordInFlight
                    || self.appState.sttRouter.isRecording
            }
            meetingPromptDetector.ownCaptureActivity = { [weak self] in
                guard let self else { return .none }
                if self.appState.meetingSession.isCaptureSessionActive
                    || self.meetingPromptRecordInFlight {
                    return .meetingRecording
                }
                if self.appState.sttRouter.isRecording {
                    return .dictation
                }
                return .none
            }
            meetingPromptDetector.isMicInputPromptEnabled = {
                AutoCallDetectionPreferences.isEnabled()
            }
            // Assigned before start(), same contract as onChange/onOutputChange
            // below. Injected rather than a direct `DefaultInputDeviceMonitor
            // .shared` reference inside MicActivityMonitor.swift itself, so
            // that file's pure attribution helpers (Tests/MicActivityMonitorTests.swift)
            // stay compilable by the fast-test runner without pulling in
            // DefaultInputDeviceMonitor.swift's EventReporter dependency graph.
            micActivityMonitor.defaultInputDeviceMonitor = DefaultInputDeviceMonitor.shared
            micActivityMonitor.onChange = { [weak self] micUsers in
                self?.meetingPromptDetector.updateMicInputUsers(micUsers)
            }
            // Native-app audio output is the listen-only call signal (remote
            // people talking, nothing holding the mic here). Same prompt pipe;
            // the detector de-dupes it against the mic and camera signals.
            micActivityMonitor.onOutputChange = { [weak self] outputUsers in
                self?.meetingPromptDetector.updateAudioOutputUsers(outputUsers)
            }
            // A browser playing audio while it holds the mic: corroboration
            // that an unrecognized browser mic is a conversation. Never a
            // prompt on its own.
            micActivityMonitor.onBrowserOutputChange = { [weak self] browserOutputUsers in
                self?.meetingPromptDetector.updateBrowserOutputUsers(browserOutputUsers)
            }
            // Camera-on is a second, complementary call sensor (e.g. a camera-on,
            // mic-muted Meet join). It feeds the same prompt; the detector de-dupes
            // it against the mic signal so a normal video call prompts once.
            cameraActivityMonitor.onChange = { [weak self] cameraInUse in
                self?.meetingPromptDetector.updateCameraInUse(cameraInUse)
            }
            meetingPromptDetector.start()
            applyAutoCallDetectionPreference()
            observeAutoCallDetectionPreference()
            // A call that starts during dictation is gated by own-capture.
            // When dictation ends, re-evaluate immediately so the prompt
            // is not stuck waiting for the 120s poll.
            appState.sttRouter.$isRecording
                .removeDuplicates()
                .dropFirst()
                .filter { !$0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.meetingPromptDetector.requestEvaluation()
                }
                .store(in: &meetingPromptSubscriptions)
            appState.contextCapture.onMeetingToggle = { [weak self] in
                self?.meetingOverlayController.toggleFromHotkey()
            }
            SpeakerNamingSheet.shared.island = notchIsland
            // Only the island lists voices named on their own ("who was on
            // the call"), so only then does a meeting with nobody to ask get
            // a review; the window has nothing to show for it.
            meetingSession.taskManager.reviewListsRecognizedVoicesProvider = { true }
            SpeakerNamingSheet.shared.onOpenTranscript = { [weak self] transcriptURL in
                self?.settingsWindowController.revealMeeting(
                    transcriptURL: transcriptURL,
                    source: "meeting_overlay"
                )
            }
            SpeakerNamingSheet.shared.observe(
                requests: meetingSession.speakerNamingRequests,
                meetingCaptureActive: meetingSession.$state
                    .map { MeetingSessionStateMachine.isCaptureSessionActive($0) }
                    .eraseToAnyPublisher()
            )
        }

        // Set up menubar status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            configureStatusItemButton(button)
        }
        LaunchTimingTelemetry.markStatusItemShownAfterThisTurn()
        bindStatusItemUpdateBadge()
        bindStatusItemRecordingIndicator()

        // Set up popover (pure AppKit — no NSHostingController, no AttributeGraph)
        let pop = NSPopover()
        pop.contentSize = NSSize(width: MenuTokens.panelWidth, height: MenuTokens.panelHeight)
        pop.behavior = .transient
        pop.delegate = self
        popover = pop
        // Shortcuts go live before the Home window and engine setup, so a key press
        // during the rest of launch is queued (the tap has its own thread), not lost.
        appState.contextCapture.registerHotkey()
        LaunchTimingTelemetry.markHotkeysRegistered()

        writeLaunchUISmokeReportIfRequested()

        // Engine recovery on wake — hotkeys and overlay state
        let wakeRecoveryObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.appState.handleSystemWake()
                self.overlayController.handleSystemWake()
            }
        }
        workspaceObservers.append(wakeRecoveryObserver)

        presentInitialOnboardingIfNeeded()
        if LaunchWindowPolicy.shouldOpenMainWindow(
            launchedAsLoginItem: launchedAsLoginItem,
            secondsSinceLogin: Self.secondsSinceConsoleLoginNotingLaunch(launchedAsLoginItem: launchedAsLoginItem),
            onboardingCompleted: PermissionsOnboardingPreferences.hasCompleted(),
            isAutomatedLaunch: AutomatedLaunchEnvironment.isActive()
        ) {
            showSettingsWindow(page: .today, source: "app_launch")
        }

        // Initialize engines
        Task { @MainActor in
            await appState.initialize()
            await writeFirstRunReliabilityReportIfRequested()
        }
        CompanionConnectionService.shared.configure(meetingSession: appState.meetingSession)
        #if TRANSCRIPTED_LAB_CONTROL
        // Lab builds only (`build.sh --lab`); see docs/lab-control-channel.md.
        LabControlChannel.startIfRequested(appDelegate: self)
        #endif
        #if TRANSCRIPTED_DEBUG_CONTROL
        // Debug builds only (`build.sh`); see docs/debug-control-surface.md.
        DebugControlChannel.startIfRequested(appDelegate: self)
        #endif
    }

    #if TRANSCRIPTED_DEBUG_CONTROL
    func application(_ application: NSApplication, open urls: [URL]) {
        DebugControlChannel.handleOpenURLs(urls, appDelegate: self)
    }
    #endif

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            // Let AppKit do its default handling (bring an existing
            // window to the front).
            return true
        }

        if !PermissionsOnboardingPreferences.hasCompleted() {
            _ = resolvedSourceApp()
            onboardingWindowController.present(entrypoint: "dock_icon")
            return false
        }

        showSettingsWindow(page: .today, source: "dock_icon")
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if duplicateInstanceShouldTerminateImmediately {
            return
        }

        persistentDictationInputController.stopMonitoring()
        // A paste may still be waiting to put the user's clipboard back.
        ClipboardRestoringTextPaster.restorePendingClipboardsBeforeQuit()

        if onboardingWindowController.isVisible {
            NotificationCenter.default.post(name: .transcriptedOnboardingWillTerminate, object: nil)
        }

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = singleInstanceReopenObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            singleInstanceReopenObserver = nil
        }
        if let observer = micPreferenceObserver {
            NotificationCenter.default.removeObserver(observer)
            micPreferenceObserver = nil
        }
        if #available(macOS 14.0, *) {
            meetingPromptDetector.stop()
            micActivityMonitor.stop()
            cameraActivityMonitor.stop()
        }
        appState.shutdown()
        CrashReporter.endSession()
        singleInstanceGuard.release()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WritingController.noteTerminationRequest()
        if duplicateInstanceShouldTerminateImmediately {
            return .terminateNow
        }

        if terminationCleanupFinished {
            return .terminateNow
        }
        guard !terminationCleanupStarted else {
            pendingTerminationReplyCount += 1
            return .terminateLater
        }
        switch activeMeetingTerminationDecision() {
        case .keepRecording:
            return .terminateCancel
        case .stopAndTranscribe:
            Task { @MainActor [weak self] in
                guard let self else { return }
                if #available(macOS 14.0, *) {
                    // stopRecording() alone only accepts .recording — if the
                    // meeting is still engaging the mic (.startingRecording)
                    // when this explicit "Stop Recording" choice lands,
                    // a bare stopRecording() call would silently no-op and
                    // the pending start would go on to leave the meeting
                    // recording, contradicting what the user just chose.
                    await self.appState.meetingSession.stopRecordingJoiningPendingStart(reason: .quitConfirmation)
                }
            }
            return .terminateCancel
        case .saveAudioAndQuit:
            break
        }

        terminationCleanupStarted = true
        pendingTerminationReplyCount = 1

        Task { @MainActor [weak self, sender] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }

            await AppTerminationSequence.run(AppTerminationSequence.Steps(
                finishDictationForTermination: { await self.sessionController.finishDictationForTermination() },
                resetCleanupAdmission: { self.terminationCleanupStarted = false },
                prepareMeetingForTermination: {
                    if #available(macOS 14.0, *) {
                        await self.appState.meetingSession.prepareForTermination()
                    }
                },
                shutDownAppState: { self.appState.shutdown() },
                stopAndRestorePersistentInput: { await self.persistentDictationInputController.stopAndRestore() },
                flushLocalEvents: { await EventReporter.shared.flushLocalEventsForShutdown() },
                markCleanupFinished: { self.terminationCleanupFinished = true },
                replyToPendingRequests: { self.replyToPendingTerminationRequests(sender, shouldTerminate: $0) }
            ))
        }

        return .terminateLater
    }

    private func acquireSingleInstanceLock() -> Bool {
        switch singleInstanceGuard.acquire() {
        case .acquired:
            installSingleInstanceReopenHandler()
            return true
        case .alreadyRunning:
            duplicateInstanceShouldTerminateImmediately = true
            SingleInstanceGuard.requestExistingInstanceToPresent()
            SingleInstanceGuard.activateExistingInstance()
            NSApp.terminate(nil)
            return false
        }
    }

    private func installSingleInstanceReopenHandler() {
        guard singleInstanceReopenObserver == nil else { return }

        singleInstanceReopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: SingleInstanceGuard.reopenNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSingleInstanceReopenRequest()
            }
        }
    }

    private func handleSingleInstanceReopenRequest() {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)

        // Reopening must not start an app-modal event loop (see
        // SingleInstanceReopenPolicy); the instance lock still keeps the newly
        // launched copy from touching shared recording state.
        let button = statusItem?.button
        switch SingleInstanceReopenPolicy.surface(
            onboardingComplete: PermissionsOnboardingPreferences.hasCompleted(),
            hasStatusItem: button != nil && popover != nil
        ) {
        case .onboarding:
            onboardingWindowController.present(entrypoint: "single_instance_reopen")
        case .popover:
            if let button, let popover {
                showMainPopover(relativeTo: button, popover: popover, entrypoint: "single_instance_reopen")
            }
        case .settingsFallback:
            showSettingsWindow(page: .today, source: "single_instance_reopen")
        }
    }

    @objc func togglePopover() {
        if !PermissionsOnboardingPreferences.hasCompleted() {
            _ = resolvedSourceApp()
            onboardingWindowController.present(entrypoint: "status_item")
            return
        }

        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            closePopover()
        } else {
            showMainPopover(relativeTo: button, popover: popover)
        }
    }

    private func configureStatusItemButton(_ button: NSStatusBarButton) {
        StatusItemPresentation.apply(to: button, meetingRecording: false, dictating: false, updateTooltip: nil)
        button.imagePosition = .imageOnly
        button.identifier = NSUserInterfaceItemIdentifier(MenuBarAutomationID.statusItemButton.rawValue)
        button.setAccessibilityIdentifier(MenuBarAutomationID.statusItemButton.rawValue)
        MenuBarPopoverPresentation.installToggleAction(on: button, target: self, action: #selector(togglePopover))

        installStatusItemUpdateBadge(on: button)
    }

    /// The status item's glyph, tint, tooltip, and label for the current
    /// capture state; `StatusItemPresentation.apply` is the single writer.
    func refreshStatusItemPresentation() {
        guard let button = statusItem?.button else { return }
        StatusItemPresentation.apply(
            to: button,
            meetingRecording: statusItemMeetingRecording,
            dictating: statusItemDictationRecording,
            updateTooltip: statusItemUpdateTooltip
        )
    }

    // MARK: - Menu Bar Commands

    /// Thin entry points for `TranscriptedMenuCommands`, reusing the action
    /// helpers in the `TranscriptedAppDelegate+*` extensions. Each one mirrors
    /// a path users already have via the popover, the sidebar, or a recordable
    /// trigger — nothing here remaps those triggers.

    func menuStartDictation() {
        startDictationFromSettings()
    }

    func menuToggleMeetingRecording() {
        guard #available(macOS 14.0, *) else {
            NSSound.beep()
            return
        }
        // Same start/stop toggle the meeting trigger uses, so ⌘R behaves like
        // the recordable meeting shortcut.
        meetingOverlayController.toggleFromHotkey()
    }

    func menuImportAudio() {
        importAudioFileFromSettings()
    }

    func menuOpenPage(_ page: TranscriptedSettingsPage) {
        showSettingsWindow(page: page, source: "menu_command")
    }

    func menuOpenSettings() {
        closePopover()
        showSettingsWindow(page: .general, source: "app_menu")
    }

    func menuFindSpeaker() {
        settingsWindowController.focusSpeakerSearch(source: "menu_command")
    }

    func menuFindCaptures() {
        settingsWindowController.focusHomeFind(source: "menu_command")
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        menuPanelController.prepareForClose()
        if popover?.contentViewController !== menuPanelController {
            popover?.contentViewController = nil
        }
    }
}

extension DictationSessionController: AppLaunchDictationHost {}

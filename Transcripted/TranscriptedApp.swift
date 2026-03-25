import SwiftUI
import AppKit
import AVFoundation
import Combine
import UserNotifications
#if canImport(Sparkle)
import Sparkle
#endif

@available(macOS 26.0, *)
@main
struct TranscriptedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate (Slim Coordinator)
// Extensions in: MenuBarManager.swift, HotkeyManager.swift, NotificationCoordinator.swift,
//                WindowCoordinator.swift, RecordingCoordinator.swift, AppDelegateDebug.swift

@available(macOS 26.0, *)
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem?
    var floatingPanel: FloatingPanelController?
    var failedTranscriptionManager: FailedTranscriptionManager?
    var taskManager: TranscriptionTaskManager?
    var audio: Audio?
    var failedTranscriptionsWindow: NSWindow?

    var settingsWindowController: SettingsWindowController?
    var meetingDetector: MeetingDetector?
    var onboardingWindowController: OnboardingWindowController?
    var pillCalloutController: PillCalloutController?

    #if canImport(Sparkle)
    var updaterController: SPUStandardUpdaterController?
    #endif

    // Hotkey monitors (accessed by HotkeyManager extension)
    var globalHotkeyMonitor: Any?
    var localHotkeyMonitor: Any?

    // Menu bar state (accessed by MenuBarManager extension)
    var todayStatRow: MenuBarStatRow?
    var weekStatRow: MenuBarStatRow?
    var streakStatRow: MenuBarStatRow?
    var recordingToggleMenuItem: NSMenuItem?
    var failedMenuItem: NSMenuItem?
    var processingMenuItem: NSMenuItem?
    var durationTimer: Timer?
    var cancellables = Set<AnyCancellable>()
    let terracottaColor = NSColor(red: 0.855, green: 0.467, blue: 0.337, alpha: 1.0)

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // XCTest injects a test bundle into the host app. If full app initialization
        // runs (Audio, CoreAudio, ScreenCaptureKit, FloatingPanel, etc.) it can block
        // the main thread long enough for the test runner to time out before connecting.
        // Early-returning here lets XCTest establish its connection; tests use
        // @testable import so they access types directly without needing app state.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }

        _ = AppLogger.shared

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        print("[Transcripted] v\(version) build \(build)")

        UserDefaults.standard.set(1000, forKey: "NSInitialToolTipDelay")
        NSApp.setActivationPolicy(.accessory)

        if !OnboardingState.hasCompletedOnboarding() {
            showOnboarding()
            return
        }

        setupApp()
    }

    private func showOnboarding() {
        onboardingWindowController = OnboardingWindowController(onComplete: { [weak self] in
            self?.onboardingWindowController = nil
            self?.setupApp()
        })
        onboardingWindowController?.showWithAnimation()
    }

    /// Set up the main app after onboarding or on subsequent launches
    func setupApp() {
        #if canImport(Sparkle)
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif

        registerNotificationCategories()
        setupMenuBar()

        // Initialize managers
        let ftm = FailedTranscriptionManager()
        let aud = Audio()
        let tm = TranscriptionTaskManager(failedTranscriptionManager: ftm)
        failedTranscriptionManager = ftm
        audio = aud
        taskManager = tm

        cleanupOrphanedAudioFiles(failedManager: ftm)

        // Initialize models in background
        AppLogger.app.info("Creating model init task")
        Task { @MainActor in
            AppLogger.app.info("Starting model initialization")
            async let modelsReady: Void = tm.transcription.initializeModels()
            async let qwenCached: Void = Self.preCacheQwenIfNeeded()
            await modelsReady
            await qwenCached
            AppLogger.app.info("Model initialization complete")
        }

        // Wire up recording callbacks
        aud.onRecordingStart = { [weak self] in
            Task { @MainActor in
                self?.taskManager?.prepareForRecording()
            }
        }
        aud.onRecordingComplete = { [weak self] micURL, systemURL in
            self?.handleRecordingComplete(micURL: micURL, systemURL: systemURL)
        }

        // Set up meeting auto-detection
        let detector = MeetingDetector(audio: aud)
        detector.onMeetingStart = { [weak self] appName in
            guard let audio = self?.audio, !audio.isRecording else { return }
            AppLogger.app.info("Auto-start: meeting detected", ["app": appName])
            audio.start()
            self?.sendAutoDetectStartNotification(appName: appName)
        }
        detector.onMeetingEnd = { [weak self] in
            guard let audio = self?.audio, audio.isRecording else { return }
            let duration = audio.recordingDuration
            AppLogger.app.info("Auto-stop: meeting ended", ["duration": "\(Int(duration))s"])
            audio.stop()
            self?.sendAutoDetectStopNotification(duration: duration)
        }
        detector.start()
        meetingDetector = detector

        // Create floating panel
        floatingPanel = FloatingPanelController(
            taskManager: tm,
            audio: aud,
            failedTranscriptionManager: ftm
        )
        floatingPanel?.showWindow(nil)

        // Show pill callout for first-time users
        if !OnboardingState.hasShownPillCallout() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let pillWindow = self?.floatingPanel?.window else { return }
                self?.floatingPanel?.pillStateManager.showOnboardingGlow = true
                self?.pillCalloutController = PillCalloutController(
                    pillFrame: pillWindow.frame,
                    onDismiss: { [weak self] in
                        OnboardingState.markPillCalloutShown()
                        self?.floatingPanel?.pillStateManager.showOnboardingGlow = false
                        self?.pillCalloutController?.window?.orderOut(nil)
                        self?.pillCalloutController = nil
                    }
                )
                self?.pillCalloutController?.showWindow(nil)
            }
        }

        subscribeToRecordingState()
        registerGlobalHotkey()
        updateStatusBarTitle()
    }

    // MARK: - NSMenuDelegate (forwarded to MenuBarManager extension)

    func menuWillOpen(_ menu: NSMenu) {
        menuBarWillOpen(menu)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationResponse(response, completionHandler: completionHandler)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Termination

    func applicationWillTerminate(_ notification: Notification) {
        if audio?.isRecording == true {
            audio?.stop()
        }
        taskManager?.cleanupPendingNaming()
        taskManager?.cancelAll()

        cleanupHotkeyMonitors()
        stopDurationTimer()

        AppLogger.shared.flush()
    }
}

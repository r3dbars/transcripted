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

@available(macOS 26.0, *)
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem?
    var floatingPanel: FloatingPanelController?
    var failedTranscriptionManager: FailedTranscriptionManager?
    var taskManager: TranscriptionTaskManager?
    var audio: Audio?
    var failedTranscriptionsWindow: NSWindow?

    // New settings window controller (redesigned dashboard)
    var settingsWindowController: SettingsWindowController?

    // Meeting auto-detection
    var meetingDetector: MeetingDetector?

    // Onboarding
    var onboardingWindowController: OnboardingWindowController?

    // Auto-updates (Sparkle)
    #if canImport(Sparkle)
    var updaterController: SPUStandardUpdaterController?
    #endif

    // Global hotkey monitors
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?

    // Enhanced menu bar
    private var statsMenuItem: NSMenuItem?
    private var recordingToggleMenuItem: NSMenuItem?
    private var durationMenuItem: NSMenuItem?
    private var failedMenuItem: NSMenuItem?
    private var failedSeparator: NSMenuItem?
    private var processingMenuItem: NSMenuItem?
    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize logger (creates log directory, opens file handle)
        _ = AppLogger.shared

        // Log app version and build number
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        print("[Transcripted] v\(version) build \(build)")

        // Configure tooltip delay to 1 second
        UserDefaults.standard.set(1000, forKey: "NSInitialToolTipDelay")


        NSApp.setActivationPolicy(.accessory)

        // Check if onboarding is needed
        if !OnboardingState.hasCompletedOnboarding() {
            showOnboarding()
            return  // Don't set up the rest until onboarding is complete
        }

        // Normal app launch
        setupApp()
    }

    /// Show the onboarding window for first-time users
    private func showOnboarding() {
        onboardingWindowController = OnboardingWindowController(onComplete: { [weak self] in
            // Onboarding complete - now set up the app
            self?.onboardingWindowController = nil
            self?.setupApp()
        })
        onboardingWindowController?.showWithAnimation()
    }

    /// Set up the main app after onboarding or on subsequent launches
    private func setupApp() {
        // Initialize Sparkle auto-updater
        #if canImport(Sparkle)
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif

        // Register notification categories and request permission
        registerNotificationCategories()

        // Setup menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Transcripted")
            button.action = #selector(statusBarClicked)
            button.target = self
        }

        let menu = NSMenu()
        menu.delegate = self

        // Stats line (disabled, gray text)
        let stats = NSMenuItem(title: "No meetings yet", action: nil, keyEquivalent: "")
        stats.isEnabled = false
        statsMenuItem = stats
        menu.addItem(stats)

        menu.addItem(NSMenuItem.separator())

        // Start/Stop Recording with hotkey hint
        let toggleItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "R")
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        recordingToggleMenuItem = toggleItem
        menu.addItem(toggleItem)

        // Duration display (hidden when not recording)
        let durationItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        durationItem.isHidden = true
        durationItem.isEnabled = false
        durationMenuItem = durationItem
        menu.addItem(durationItem)

        menu.addItem(NSMenuItem.separator())

        // Recent Transcripts (5 slots, populated dynamically)
        for _ in 0..<5 {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isHidden = true
            item.tag = 100
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "Open Transcripts Folder...", action: #selector(openTranscriptsFolder), keyEquivalent: ""))

        // Conditional status section (failed + processing)
        let failSep = NSMenuItem.separator()
        failSep.isHidden = true
        failedSeparator = failSep
        menu.addItem(failSep)

        let failed = NSMenuItem(title: "Failed Transcriptions...", action: #selector(openFailedTranscriptions), keyEquivalent: "")
        failed.isHidden = true
        failedMenuItem = failed
        menu.addItem(failed)

        let processing = NSMenuItem(title: "Transcribing...", action: nil, keyEquivalent: "")
        processing.isHidden = true
        processing.isEnabled = false
        processingMenuItem = processing
        menu.addItem(processing)

        menu.addItem(NSMenuItem.separator())

        // Settings & Updates
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        #if canImport(Sparkle)
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: ""))
        #endif

        menu.addItem(NSMenuItem.separator())

        // Help submenu
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu()
        helpMenu.addItem(NSMenuItem(title: "Report a Bug...", action: #selector(reportIssue), keyEquivalent: ""))
        helpMenu.addItem(NSMenuItem(title: "Export Diagnostics...", action: #selector(exportDiagnostics), keyEquivalent: ""))
        helpMenu.addItem(NSMenuItem.separator())
        helpMenu.addItem(NSMenuItem(title: "Show/Hide Pill", action: #selector(toggleWindow), keyEquivalent: ""))
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)

        #if DEBUG
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Reset Onboarding (Debug)", action: #selector(resetOnboarding), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Test Naming Tray (Debug)", action: #selector(testNamingTray), keyEquivalent: ""))
        #endif

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Transcripted", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Initialize managers (all inits are non-failable — no guard needed)
        let ftm = FailedTranscriptionManager()
        let aud = Audio()
        let tm = TranscriptionTaskManager(failedTranscriptionManager: ftm)
        failedTranscriptionManager = ftm
        audio = aud
        taskManager = tm

        // Clean up orphaned audio files from previous crashes
        cleanupOrphanedAudioFiles(failedManager: ftm)

        // Initialize local models in background (Parakeet + Sortformer + Qwen pre-cache in parallel)
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

        // Dynamic menu bar icon: changes when recording starts/stops
        aud.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                guard let button = self?.statusItem?.button else { return }
                if isRecording {
                    button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
                    button.contentTintColor = .systemRed
                    self?.recordingToggleMenuItem?.title = "Stop Recording"
                    self?.startDurationTimer()
                } else {
                    button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Transcripted")
                    button.contentTintColor = nil
                    self?.recordingToggleMenuItem?.title = "Start Recording"
                    self?.stopDurationTimer()
                }
            }
            .store(in: &cancellables)

        // Register global hotkey: ⌘⇧R to toggle recording
        registerGlobalHotkey()
    }

    /// Delete orphaned audio files (meeting_*_mic.wav, meeting_*_system.wav) that are not
    /// referenced by the failed transcription queue. These can persist after crashes when
    /// the app exits between recording and transcription completion.
    private func cleanupOrphanedAudioFiles(failedManager: FailedTranscriptionManager) {
        let saveDir = TranscriptSaver.defaultSaveDirectory
        guard FileManager.default.fileExists(atPath: saveDir.path) else { return }

        // Collect all audio URLs referenced by the failed transcription queue
        var referencedPaths: Set<String> = []
        for failed in failedManager.failedTranscriptions {
            referencedPaths.insert(failed.micAudioURL.path)
            if let systemURL = failed.systemAudioURL {
                referencedPaths.insert(systemURL.path)
            }
        }

        // Scan for orphaned meeting audio files
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: saveDir,
            includingPropertiesForKeys: nil
        ) else { return }

        var deletedCount = 0
        for fileURL in contents {
            let name = fileURL.lastPathComponent
            guard name.hasPrefix("meeting_"),
                  (name.hasSuffix("_mic.wav") || name.hasSuffix("_system.wav")),
                  !referencedPaths.contains(fileURL.path) else { continue }

            do {
                try FileManager.default.removeItem(at: fileURL)
                deletedCount += 1
            } catch {
                AppLogger.app.warning("Failed to delete orphaned audio file", ["file": name, "error": error.localizedDescription])
            }
        }

        if deletedCount > 0 {
            AppLogger.app.info("Cleaned up orphaned audio files", ["count": "\(deletedCount)"])
        }
    }

    /// Pre-cache Qwen model so it's ready for first recording.
    /// Downloads model files if enabled but not yet cached, then frees memory.
    private static func preCacheQwenIfNeeded() async {
        guard QwenService.isEnabled, !QwenService.isModelCached else { return }
        AppLogger.app.info("Pre-caching Qwen model in background")
        let qwen = QwenService()
        await qwen.loadModel()
        switch qwen.modelState {
        case .ready:
            qwen.unload()  // Free memory — just wanted to cache the files
            AppLogger.app.info("Qwen model pre-cached successfully")
        case .failed(let error):
            AppLogger.app.error("Qwen model pre-cache failed", ["error": error])
        default:
            AppLogger.app.warning("Qwen model pre-cache ended in unexpected state")
        }
    }

    #if DEBUG
    @objc func resetOnboarding() {
        OnboardingState.resetOnboarding()
        AppLogger.app.info("Onboarding reset — restart app to see onboarding")
    }

    @objc func testNamingTray() {
        guard let tm = taskManager else { return }
        let speakerDB = tm.transcription.speakerDB

        // Seed DB with test profiles so merge suggestions appear
        let mkbhdEmbedding = (0..<256).map { _ in Float.random(in: -1...1) }
        let travisEmbedding = (0..<256).map { _ in Float.random(in: -1...1) }
        let mkbhdProfile = speakerDB.addOrUpdateSpeaker(embedding: mkbhdEmbedding)
        speakerDB.setDisplayName(id: mkbhdProfile.id, name: "MKBHD", source: "user_manual")
        // Bump call count by adding a few more times
        for _ in 0..<6 {
            _ = speakerDB.addOrUpdateSpeaker(embedding: mkbhdEmbedding, existingId: mkbhdProfile.id)
        }
        let travisProfile = speakerDB.addOrUpdateSpeaker(embedding: travisEmbedding)
        speakerDB.setDisplayName(id: travisProfile.id, name: "Travis", source: "user_manual")
        for _ in 0..<2 {
            _ = speakerDB.addOrUpdateSpeaker(embedding: travisEmbedding, existingId: travisProfile.id)
        }

        // Create tiny silence WAV files for clip playback
        let clip1 = createSilentWAV(name: "test_speaker_0")
        let clip2 = createSilentWAV(name: "test_speaker_1")

        // Create test naming entries — one unknown, one needing confirmation
        let unknownId = UUID()
        let knownId = UUID()
        // Insert into DB so merge targets exist
        let unknownProfile = speakerDB.addOrUpdateSpeaker(embedding: (0..<256).map { _ in Float.random(in: -1...1) })
        let knownProfile = speakerDB.addOrUpdateSpeaker(embedding: (0..<256).map { _ in Float.random(in: -1...1) })

        let entries = [
            SpeakerNamingEntry(
                id: unknownProfile.id,
                sortformerSpeakerId: "0",
                clipURL: clip1,
                sampleText: "I think the new MacBook Pro is incredible this year, the M4 chip is a huge leap forward",
                currentName: nil,
                matchSimilarity: nil,
                needsNaming: true,
                needsConfirmation: false,
                qwenResult: .notAttempted
            ),
            SpeakerNamingEntry(
                id: knownProfile.id,
                sortformerSpeakerId: "1",
                clipURL: clip2,
                sampleText: "Yeah the battery life improvements are really what sold me on upgrading",
                currentName: "Travis",
                matchSimilarity: 0.72,
                needsNaming: false,
                needsConfirmation: true,
                qwenResult: .notAttempted
            )
        ]

        // Create a dummy transcript URL (doesn't need to exist for testing)
        let dummyTranscript = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_transcript.md")
        let dummyMic = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_mic.wav")
        let dummySystem = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_system.wav")

        tm.speakerNamingRequest = SpeakerNamingRequest(
            speakers: entries,
            transcriptURL: dummyTranscript,
            systemAudioURL: dummySystem,
            micAudioURL: dummyMic,
            onComplete: { [weak tm] updates in
                tm?.handleNamingComplete(
                    updates: updates,
                    transcriptURL: dummyTranscript,
                    micURL: dummyMic,
                    systemURL: dummySystem,
                    clips: entries
                )
            }
        )

        AppLogger.app.info("Debug: Test naming tray triggered", ["speakers": "\(entries.count)"])
    }

    /// Create a tiny silent WAV file for debug clip playback
    private func createSilentWAV(name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000) else {
            return url
        }
        buffer.frameLength = 24000  // 0.5 seconds of silence
        if let file = try? AVAudioFile(forWriting: url, settings: format.settings) {
            try? file.write(from: buffer)
        }
        return url
    }
    #endif

    // MARK: - Notifications

    /// Register notification categories and request permission (call once during setupApp)
    private func registerNotificationCategories() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // "Stop" action for auto-detect recording notifications
        let stopAction = UNNotificationAction(
            identifier: "STOP_RECORDING",
            title: "Stop",
            options: .destructive
        )
        let autoDetectCategory = UNNotificationCategory(
            identifier: "AUTO_DETECT_RECORDING",
            actions: [stopAction],
            intentIdentifiers: []
        )

        // "Show in Finder" action for transcript saved notifications
        let showAction = UNNotificationAction(
            identifier: TranscriptSaver.showInFinderActionId,
            title: "Show in Finder",
            options: .foreground
        )
        let savedCategory = UNNotificationCategory(
            identifier: TranscriptSaver.notificationCategoryId,
            actions: [showAction],
            intentIdentifiers: []
        )

        center.setNotificationCategories([autoDetectCategory, savedCategory])

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                AppLogger.app.info("Notification permission granted")
            } else if let error = error {
                AppLogger.app.warning("Notification permission error", ["error": error.localizedDescription])
            } else {
                AppLogger.app.info("Notification permission denied by user")
            }
        }
    }

    /// Notify user that auto-detect started a recording.
    /// Guards on authorization status to avoid UNErrorDomain error 1.
    private func sendAutoDetectStartNotification(appName: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                AppLogger.app.debug("Skipping auto-detect start notification — not authorized")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Recording Started"
            content.body = "Transcripted detected \(appName) and started recording."
            content.categoryIdentifier = "AUTO_DETECT_RECORDING"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "auto-detect-start",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Notify user that auto-detect stopped a recording.
    /// Guards on authorization status to avoid UNErrorDomain error 1.
    private func sendAutoDetectStopNotification(duration: TimeInterval) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                AppLogger.app.debug("Skipping auto-detect stop notification — not authorized")
                return
            }

            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            let durationStr = String(format: "%d:%02d", minutes, seconds)

            let content = UNMutableNotificationContent()
            content.title = "Recording Saved"
            content.body = "\(durationStr) meeting transcribed."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "auto-detect-stop",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        Task { @MainActor in
            switch actionId {
            case "STOP_RECORDING":
                self.audio?.stop()
            case TranscriptSaver.showInFinderActionId:
                if let path = userInfo["fileURL"] as? String {
                    let url = URL(fileURLWithPath: path)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            default:
                break
            }
        }

        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Recording Toggle (shared by hotkey + menu)

    @objc func toggleRecording() {
        guard let audio = audio else { return }
        if audio.isRecording {
            audio.stop()
        } else {
            audio.start()
        }
    }

    // MARK: - Global Hotkey (⌘⇧R)

    private func registerGlobalHotkey() {
        // Global monitor: catches ⌘⇧R when OTHER apps are frontmost
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains([.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "r" {
                DispatchQueue.main.async {
                    self?.toggleRecording()
                }
            }
        }
        // Local monitor: catches ⌘⇧R when THIS app is frontmost
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains([.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "r" {
                DispatchQueue.main.async {
                    self?.toggleRecording()
                }
                return nil  // consume the event
            }
            return event
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Update stats line
        let totalRec = StatsService.shared.totalRecordings
        let totalHrs = StatsService.shared.totalHoursTranscribed
        if totalRec > 0 {
            let hrsStr = totalHrs < 1 ? String(format: "%.0fm", totalHrs * 60) : String(format: "%.1f hrs", totalHrs)
            statsMenuItem?.title = "\(totalRec) meeting\(totalRec == 1 ? "" : "s") · \(hrsStr)"
        } else {
            statsMenuItem?.title = "No meetings yet"
        }

        // Update duration display
        if let audio = audio, audio.isRecording {
            let totalSeconds = Int(audio.recordingDuration)
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            durationMenuItem?.title = String(format: "  ● Recording: %d:%02d", minutes, seconds)
            durationMenuItem?.isHidden = false
        } else {
            durationMenuItem?.isHidden = true
        }

        // Populate recent transcripts with human-readable labels
        let recentItems = menu.items.filter { $0.tag == 100 }
        let saveDir = TranscriptSaver.defaultSaveDirectory

        var recentSummaries: [(label: String, url: URL)] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.pathExtension == "md" }) {
            let sorted = files.sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return aDate > bDate
            }
            recentSummaries = sorted.prefix(5).map { url in
                (label: Self.formatMenuLabel(for: url), url: url)
            }
        }

        for (index, item) in recentItems.enumerated() {
            if index < recentSummaries.count {
                let summary = recentSummaries[index]
                item.title = summary.label
                item.representedObject = summary.url
                item.action = #selector(openRecentTranscript(_:))
                item.target = self
                item.isHidden = false
                item.isEnabled = true
            } else {
                item.isHidden = true
            }
        }

        // Conditional: failed transcriptions
        let failedCount = failedTranscriptionManager?.failedTranscriptions.count ?? 0
        if failedCount > 0 {
            failedMenuItem?.title = "⚠ \(failedCount) Failed — Retry..."
            failedMenuItem?.isHidden = false
            failedSeparator?.isHidden = false
        } else {
            failedMenuItem?.isHidden = true
            failedSeparator?.isHidden = failedCount == 0 && !(taskManager?.displayStatus.isProcessing ?? false)
        }

        // Conditional: processing status
        if let status = taskManager?.displayStatus, status.isProcessing {
            let pct = Int(status.progress * 100)
            processingMenuItem?.title = "\(status.statusText) \(pct)%"
            processingMenuItem?.isHidden = false
            failedSeparator?.isHidden = false
        } else {
            processingMenuItem?.isHidden = true
        }
    }

    // MARK: - Menu Label Formatting

    /// Build a human-readable label for a transcript file in the menu.
    /// Format: "Title · Today 2:30 PM" or "Today at 2:30 PM · 3 speakers"
    private static func formatMenuLabel(for url: URL) -> String {
        // Quick-parse YAML frontmatter for title, date, time, speaker info
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return url.deletingPathExtension().lastPathComponent
        }

        var title: String? = nil
        var dateStr: String? = nil
        var timeStr: String? = nil
        var speakerCount = 0
        var speakerNames: [String] = []

        if raw.hasPrefix("---"),
           let endRange = raw.range(of: "\n---\n", range: raw.index(raw.startIndex, offsetBy: 3)..<raw.endIndex) {
            let yaml = String(raw[raw.index(raw.startIndex, offsetBy: 4)..<endRange.lowerBound])

            for line in yaml.components(separatedBy: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let key = parts[0]
                let val = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))

                switch key {
                case "title": if !val.isEmpty { title = val }
                case "date": dateStr = val
                case "time": timeStr = val
                case "mic_speakers", "system_speakers":
                    speakerCount += Int(val) ?? 0
                default: break
                }
            }

            // Parse speaker names
            var inSpeakers = false
            for line in yaml.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("speakers:") { inSpeakers = true; continue }
                if inSpeakers && !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty { inSpeakers = false }
                if inSpeakers && trimmed.hasPrefix("name:") {
                    let name = trimmed.replacingOccurrences(of: "name:", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    if !name.isEmpty && name != "Unknown" && name != "You" && !name.hasPrefix("Speaker ") {
                        speakerNames.append(name)
                    }
                }
            }
        }

        // Build date component
        let dateComponent: String
        if let ds = dateStr, let ts = timeStr {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
            if let d = df.date(from: ds), let t = tf.date(from: ts) {
                let cal = Calendar.current
                let timeComps = cal.dateComponents([.hour, .minute], from: t)
                if let fullDate = cal.date(bySettingHour: timeComps.hour ?? 0, minute: timeComps.minute ?? 0, second: 0, of: d) {
                    let timeFmt = DateFormatter()
                    timeFmt.dateFormat = "h:mm a"
                    let timeLabel = timeFmt.string(from: fullDate)

                    if cal.isDateInToday(d) {
                        dateComponent = "Today \(timeLabel)"
                    } else if cal.isDateInYesterday(d) {
                        dateComponent = "Yesterday \(timeLabel)"
                    } else {
                        let dayFmt = DateFormatter()
                        dayFmt.dateFormat = "MMM d"
                        dateComponent = "\(dayFmt.string(from: d)) \(timeLabel)"
                    }
                } else {
                    dateComponent = ds
                }
            } else {
                dateComponent = ds
            }
        } else {
            // Fallback to file modification date
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "h:mm a"
            let cal = Calendar.current
            if cal.isDateInToday(modDate) {
                dateComponent = "Today \(timeFmt.string(from: modDate))"
            } else if cal.isDateInYesterday(modDate) {
                dateComponent = "Yesterday \(timeFmt.string(from: modDate))"
            } else {
                let dayFmt = DateFormatter()
                dayFmt.dateFormat = "MMM d h:mm a"
                dateComponent = dayFmt.string(from: modDate)
            }
        }

        // Build speaker component
        let speakerComponent: String
        if !speakerNames.isEmpty {
            speakerComponent = speakerNames.prefix(2).joined(separator: ", ")
        } else if speakerCount > 0 {
            speakerComponent = "\(speakerCount) speaker\(speakerCount == 1 ? "" : "s")"
        } else {
            speakerComponent = ""
        }

        // Compose final label
        if let title = title {
            return speakerComponent.isEmpty ? "\(title) · \(dateComponent)" : "\(title) · \(dateComponent)"
        } else if !speakerComponent.isEmpty {
            return "\(dateComponent) · \(speakerComponent)"
        } else {
            return dateComponent
        }
    }

    @objc func openRecentTranscript(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        stopDurationTimer()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let audio = self.audio, audio.isRecording else { return }
                let totalSeconds = Int(audio.recordingDuration)
                let minutes = totalSeconds / 60
                let seconds = totalSeconds % 60
                self.durationMenuItem?.title = String(format: "  ● Recording: %d:%02d", minutes, seconds)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        durationMenuItem?.isHidden = true
    }

    @objc func statusBarClicked() {
        // Menu shows automatically
    }

    @objc func toggleWindow() {
        if let window = floatingPanel?.window {
            window.isVisible ? window.orderOut(nil) : window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func openTranscriptsFolder() {
        NSWorkspace.shared.open(TranscriptSaver.defaultSaveDirectory)
    }

    @objc func openFailedTranscriptions() {
        guard let ftm = failedTranscriptionManager, let tm = taskManager else {
            AppLogger.app.error("Cannot open failed transcriptions — managers not initialized")
            let alert = NSAlert()
            alert.messageText = "Unable to Open"
            alert.informativeText = "The app has not finished initializing. Please try again in a moment."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        if failedTranscriptionsWindow == nil {
            let view = FailedTranscriptionsView(
                failedManager: ftm,
                taskManager: tm
            )
            let controller = NSHostingController(rootView: view)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            window.title = "Failed Transcriptions"
            window.center()
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 600, height: 400)

            failedTranscriptionsWindow = window
        }

        failedTranscriptionsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                failedTranscriptionManager: failedTranscriptionManager,
                taskManager: taskManager
            )
        }

        settingsWindowController?.showWindow()
    }

    #if canImport(Sparkle)
    @objc func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
    #endif

    @objc func exportDiagnostics() {
        DiagnosticExporter.exportDiagnostics()
    }

    @objc func reportIssue() {
        DiagnosticExporter.reportIssue()
    }

    /// Handle recording completion - trigger transcription
    func handleRecordingComplete(micURL: URL?, systemURL: URL?) {
        guard let micURL = micURL else {
            AppLogger.app.error("No mic audio file available")
            return
        }

        AppLogger.app.info("Recording complete — starting transcription")

        // Capture recording health info before it gets reset (Phase 3: Post-hoc transparency)
        let healthInfo = audio?.createHealthInfo()
        if let health = healthInfo {
            AppLogger.app.info("Recording health", ["quality": health.captureQuality.rawValue, "gaps": "\(health.audioGaps)", "switches": "\(health.deviceSwitches)"])
        }

        // Get output folder from settings, with path safety validation
        var outputFolder: URL
        if let customPath = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !customPath.isEmpty {
            let candidateURL = URL(fileURLWithPath: customPath)
            let validation = RecordingValidator.validateSavePath(candidateURL)
            if validation.isValid {
                outputFolder = candidateURL
            } else {
                AppLogger.app.warning("Custom save path rejected, falling back to default", ["path": customPath, "reason": validation.errorMessage ?? "unknown"])
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                outputFolder = documentsPath.appendingPathComponent("Transcripted")
            }
        } else {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            outputFolder = documentsPath.appendingPathComponent("Transcripted")
        }

        // Create output folder if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        } catch {
            AppLogger.pipeline.error("Failed to create output folder", ["error": error.localizedDescription, "path": outputFolder.path])
        }

        // Start transcription in background using task manager
        taskManager?.startTranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: outputFolder,
            healthInfo: healthInfo
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop active recording so audio files are properly finalized
        if audio?.isRecording == true {
            audio?.stop()
        }
        taskManager?.cleanupPendingNaming()
        taskManager?.cancelAll()

        // Clean up hotkey monitors
        if let monitor = globalHotkeyMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localHotkeyMonitor { NSEvent.removeMonitor(monitor) }
        stopDurationTimer()

        AppLogger.shared.flush()
    }
}

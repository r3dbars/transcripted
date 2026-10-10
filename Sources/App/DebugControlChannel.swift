// DebugControlChannel.swift
// File-drop + URL-scheme hook that lets a local harness drive a debug
// build: start/stop dictation and meetings, import audio, open screens,
// change allowlisted settings, and read app state as JSON.
// Protocol: docs/debug-control-surface.md.
//
// Safety:
// - DEBUG BUILDS ONLY. This file and its launch hook in
//   TranscriptedApp.swift sit behind `#if TRANSCRIPTED_DEBUG_CONTROL`,
//   which only `build.sh` sets. `build-beta.sh` never sets it and fails
//   if the env-var name below shows up in the shipped binary.
// - Stays OFF unless AutomatedLaunchEnvironment is active AND the
//   process was launched with the control-dir env var set to an
//   absolute path. A launchctl-set env var is not enough on its own.
// - Reuses LabControlFilePolicy: 0700 dirs this uid owns, O_NOFOLLOW
//   command files, no network, no transcript text in responses.

#if TRANSCRIPTED_DEBUG_CONTROL

import AppKit
import Darwin
import Foundation

@MainActor
final class DebugControlChannel {
    static let environmentKey = "TRANSCRIPTED_DEBUG_CONTROL_DIR"
    private static let pollIntervalNanoseconds: UInt64 = 250_000_000
    private static var active: DebugControlChannel?

    private weak var appDelegate: TranscriptedAppDelegate?
    private let rootPath: String
    private let inboxURL: URL
    private let doneURL: URL
    private let responsesPath: String
    private let lastPath: String
    private var pollTask: Task<Void, Never>?
    private var unmovableFileNames: Set<String> = []
    private var pasteTarget: DebugControlPasteTargetWindow?
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init(rootURL: URL, appDelegate: TranscriptedAppDelegate) {
        self.appDelegate = appDelegate
        self.rootPath = rootURL.path
        self.inboxURL = rootURL.appendingPathComponent("inbox", isDirectory: true)
        self.doneURL = rootURL.appendingPathComponent("done", isDirectory: true)
        self.responsesPath = rootURL.appendingPathComponent("responses.jsonl", isDirectory: false).path
        self.lastPath = rootURL.appendingPathComponent("last.json", isDirectory: false).path
    }

    static func startIfRequested(
        appDelegate: TranscriptedAppDelegate,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard active == nil else { return }
        let rawValue = environment[environmentKey]
        if let refusal = DebugControlAdmission.refusal(
            harnessActive: AutomatedLaunchEnvironment.isActive(environment: environment),
            controlDirectory: rawValue
        ) {
            if rawValue != nil {
                fputs("DEBUG_CONTROL | refused: \(refusal)\n", stderr)
            }
            return
        }
        guard let rootURL = LabControlCommandParser.controlDirectoryURL(fromEnvironmentValue: rawValue) else {
            return
        }
        let channel = DebugControlChannel(rootURL: rootURL, appDelegate: appDelegate)
        if let refusal = channel.prepareDirectories() {
            fputs("DEBUG_CONTROL | disabled: \(refusal)\n", stderr)
            return
        }
        active = channel
        channel.startPolling()
        fputs("DEBUG_CONTROL | enabled (pid \(ProcessInfo.processInfo.processIdentifier))\n", stderr)
    }

    static func handleOpenURLs(_ urls: [URL], appDelegate: TranscriptedAppDelegate) {
        startIfRequested(appDelegate: appDelegate)
        guard let channel = active else { return }
        for url in urls where url.scheme == DebugControlCommandParser.urlScheme {
            Task { @MainActor in
                await channel.handleURL(url)
            }
        }
    }

    private func handleURL(_ url: URL) async {
        switch DebugControlCommandParser.parseURL(url) {
        case .success(let request):
            let outcome = await execute(request.action)
            appendResponse(DebugControlResponse(
                id: request.id,
                command: request.commandName,
                outcome: outcome,
                at: isoFormatter.string(from: Date()),
                extraResult: extraResult(for: request.action, outcome: outcome)
            ))
        case .failure(let failure):
            appendResponse(DebugControlResponse(
                id: failure.id,
                command: failure.commandName,
                outcome: .failure(failure.error),
                at: isoFormatter.string(from: Date()),
                extraResult: [:]
            ))
        }
    }

    private enum PathStatus {
        case missing
        case present(mode: UInt32, ownerUID: UInt32)
        case failed(Int32)
    }

    private static func pathStatus(_ path: String) -> PathStatus {
        var info = stat()
        if lstat(path, &info) == 0 {
            return .present(mode: UInt32(info.st_mode), ownerUID: UInt32(info.st_uid))
        }
        return errno == ENOENT ? .missing : .failed(errno)
    }

    private static var currentUID: UInt32 { UInt32(getuid()) }

    private func prepareDirectories() -> String? {
        for path in [rootPath, inboxURL.path, doneURL.path] {
            if let refusal = ensurePrivateDirectory(path) { return refusal }
        }
        return nil
    }

    private func ensurePrivateDirectory(_ path: String) -> String? {
        switch Self.pathStatus(path) {
        case .missing:
            if mkdir(path, 0o700) != 0 { return "could not create \(URL(fileURLWithPath: path).lastPathComponent)" }
            return ensurePrivateDirectory(path)
        case .present(let mode, let ownerUID):
            if let refusal = LabControlFilePolicy.directoryRefusal(
                mode: mode, ownerUID: ownerUID, currentUID: Self.currentUID
            ) {
                return "\(URL(fileURLWithPath: path).lastPathComponent) \(refusal)"
            }
            return nil
        case .failed:
            return "could not inspect \(URL(fileURLWithPath: path).lastPathComponent)"
        }
    }

    private func startPolling() {
        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await self.pollOnce()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }
    }

    private func pollOnce() async {
        if let refusal = prepareDirectories() {
            fputs("DEBUG_CONTROL | stopped: \(refusal)\n", stderr)
            pollTask?.cancel()
            return
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: inboxURL.path)) ?? []
        for name in names.sorted() where LabControlCommandParser.isInboxCommandFileName(name) {
            if unmovableFileNames.contains(name) { continue }
            await processInboxFile(name)
        }
    }

    private func processInboxFile(_ name: String) async {
        let path = inboxURL.appendingPathComponent(name, isDirectory: false).path
        let parsed: Result<DebugControlRequest, DebugControlParseFailure>
        switch readCommandFile(path) {
        case .failure(let error):
            parsed = .failure(DebugControlParseFailure(id: nil, commandName: nil, error: error))
        case .success(let data):
            parsed = DebugControlCommandParser.parse(data)
        }
        moveToDone(fileName: name, fromPath: path)
        let outcome: DebugControlOutcome
        let request: DebugControlRequest?
        switch parsed {
        case .success(let value):
            request = value
            outcome = await execute(value.action)
        case .failure(let failure):
            request = nil
            outcome = .failure(failure.error)
            appendResponse(DebugControlResponse(
                id: failure.id,
                command: failure.commandName,
                outcome: outcome,
                at: isoFormatter.string(from: Date()),
                extraResult: [:]
            ))
            return
        }
        if let request {
            appendResponse(DebugControlResponse(
                id: request.id,
                command: request.commandName,
                outcome: outcome,
                at: isoFormatter.string(from: Date()),
                extraResult: extraResult(for: request.action, outcome: outcome)
            ))
        }
    }

    private func readCommandFile(_ path: String) -> Result<Data, String> {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(errno == ELOOP ? "not_a_regular_file" : "unreadable_file") }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure("unreadable_file") }
        if let refusal = LabControlFilePolicy.commandFileRefusal(
            mode: UInt32(info.st_mode),
            ownerUID: UInt32(info.st_uid),
            currentUID: Self.currentUID,
            size: info.st_size
        ) {
            return .failure(refusal)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return .failure("unreadable_file")
            }
        }
        return .success(data)
    }

    private func moveToDone(fileName: String, fromPath sourcePath: String) {
        let destinationPath = doneURL.appendingPathComponent(fileName, isDirectory: false).path
        if rename(sourcePath, destinationPath) == 0 { return }
        if unlink(sourcePath) == 0 { return }
        unmovableFileNames.insert(fileName)
    }

    private func appendResponse(_ response: DebugControlResponse) {
        guard let line = response.jsonLine(), let blob = response.jsonData() else { return }
        writeFile(line, path: responsesPath, append: true)
        writeFile(blob, path: lastPath, append: false)
    }

    private func writeFile(_ data: Data, path: String, append: Bool) {
        let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (append ? O_APPEND : O_TRUNC)
        let fd = open(path, flags, 0o600)
        guard fd >= 0 else { return }
        defer { _ = close(fd) }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(fd, base, data.count)
        }
    }

    private func execute(_ action: DebugControlAction) async -> DebugControlOutcome {
        guard let appDelegate else { return .failure("app_unavailable") }
        let meetingSession = appDelegate.appState.meetingSession

        switch action {
        case .ping:
            return .success(["pid": String(ProcessInfo.processInfo.processIdentifier)])

        case .state:
            return .success()

        case .startDictation:
            guard !appDelegate.sessionController.isDictating else {
                return .failure("dictation_already_active")
            }
            appDelegate.sessionController.startDictation(sourceApp: nil, trigger: .menu)
            guard appDelegate.sessionController.isDictating else {
                return .failure("dictation_not_started")
            }
            _ = await waitForDictationSettle(started: true)
            return .success()

        case .stopDictation(let paste):
            guard appDelegate.sessionController.isDictating else {
                return .failure("dictation_not_active")
            }
            appDelegate.sessionController.stopDictationAndPaste(trigger: .menu, autoPaste: paste)
            _ = await waitForDictationSettle(started: false)
            return .success()

        case .startMeeting:
            if let rejection = LabControlMeetingPolicy.startRejection(meetingSession.state) {
                return .failure(rejection)
            }
            let started = await meetingSession.startRecording(trigger: .menu)
            return started ? .success() : .failure("meeting_not_started")

        case .stopMeeting:
            guard let plan = LabControlMeetingPolicy.stopPlan(meetingSession.state) else {
                return .failure("meeting_not_recording")
            }
            switch plan {
            case .joinPendingStartThenStop:
                await meetingSession.stopRecordingJoiningPendingStart(reason: .menuBarStopButton)
            case .stop:
                await meetingSession.stopRecording(reason: .menuBarStopButton)
            }
            return .success()

        case .importAudio(let path):
            if let rejection = LabControlMeetingPolicy.importRejection(meetingSession.state) {
                return .failure(rejection)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return .failure("file_not_found")
            }
            let started = await meetingSession.importAudioFile(from: URL(fileURLWithPath: path))
            return started ? .success() : .failure("import_not_started")

        case .pasteTargetOpen:
            if pasteTarget == nil {
                pasteTarget = DebugControlPasteTargetWindow()
            }
            pasteTarget?.open()
            return .success(["paste_target_open": "true"])

        case .openScreen(let screen):
            openScreen(screen, appDelegate: appDelegate)
            return .success(["open_screen": screen])

        case .settingsGet(let key):
            let value = liveSetting(key)
            return .success([key: value ? "true" : "false"])

        case .settingsSet(let key, let value):
            applySetting(key, value: value)
            return .success([key: value ? "true" : "false"])
        }
    }

    /// Yields on the main actor so session/STT work can run, then returns
    /// whether the start or stop predicate settled before the timeout.
    private func waitForDictationSettle(started: Bool) async -> Bool {
        let startedAt = LabControlClock.monotonicMilliseconds()
        while true {
            let active = appDelegate?.sessionController.isDictating ?? false
            let recording = appDelegate?.appState.sttRouter.isRecording ?? false
            let settled = started
                ? DebugControlSettlePolicy.startedSettled(dictationActive: active, sttRecording: recording)
                : DebugControlSettlePolicy.stoppedSettled(dictationActive: active)
            let elapsed = LabControlClock.monotonicMilliseconds() - startedAt
            if !DebugControlSettlePolicy.shouldKeepWaiting(elapsedMilliseconds: elapsed, settled: settled) {
                return settled
            }
            try? await Task.sleep(nanoseconds: UInt64(DebugControlSettlePolicy.pollMilliseconds) * 1_000_000)
        }
    }

    private func extraResult(for action: DebugControlAction, outcome: DebugControlOutcome) -> [String: Any] {
        guard outcome.ok, let appDelegate else { return [:] }
        switch action {
        case .state, .startDictation, .stopDictation, .startMeeting, .stopMeeting, .importAudio, .pasteTargetOpen, .openScreen:
            return liveState(appDelegate)
        case .settingsGet, .settingsSet:
            var state = liveState(appDelegate)
            for (key, value) in outcome.result {
                state[key] = value == "true"
            }
            return state
        case .ping:
            return [:]
        }
    }

    private func liveState(_ appDelegate: TranscriptedAppDelegate) -> [String: Any] {
        let meetingState = appDelegate.appState.meetingSession.state
        var settings: [String: Any] = [:]
        for key in DebugControlSettingsPolicy.keys {
            settings[key] = liveSetting(key)
        }
        let openScreen: String
        if appDelegate.onboardingWindowController.isVisible {
            openScreen = "onboarding"
        } else if appDelegate.popover?.isShown == true {
            openScreen = "menubar"
        } else {
            openScreen = appDelegate.settingsWindowController.automationScreenName() ?? "none"
        }
        return [
            "schema_version": DebugControlSchema.version,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "harness_active": true,
            "dictation_active": appDelegate.sessionController.isDictating,
            "stt_recording": appDelegate.appState.sttRouter.isRecording,
            "stt_transcribing": appDelegate.appState.sttRouter.isTranscribing,
            "stt_model_loaded": appDelegate.appState.sttRouter.isModelLoaded,
            "meeting_state": LabControlMeetingPolicy.stateName(meetingState),
            "meeting_capture_active": LabControlMeetingPolicy.isCaptureActive(meetingState),
            "open_screen": openScreen,
            "paste_target_open": pasteTarget?.isOpen ?? false,
            "settings": settings,
            "automation_ids": DebugControlAutomationIDs.menuBar,
        ]
    }

    private func liveSetting(_ key: String) -> Bool {
        switch key {
        case "show_in_dock": return DockVisibilityPreferences.isVisible()
        case "auto_detect_calls": return AutoCallDetectionPreferences.isEnabled()
        case "dictation_sounds": return UISoundPreferences.isEnabled()
        case "cleanup_pasted_text": return DictationCleanupPreferences.isEnabled()
        case "crash_reports": return CrashReportingPreferences.isEnabled()
        case "usage_stats": return AnalyticsPreferences.isEnabled()
        case "people_in_room": return LocalSpeakerPreferences.isEnabled()
        case "island_in_screen_sharing": return NotchIslandPreferences.visibleInScreenSharing()
        default: return false
        }
    }

    private func applySetting(_ key: String, value: Bool) {
        // Volatile argument domain only. The real setters write
        // UserDefaults.standard (the owner's com.justinbetker.draft plist);
        // HOME / TRANSCRIPTED_CONTAINER_DIR do not isolate that. Launch
        // already puts telemetry-off flags in this domain — merge, don't replace.
        guard let persistKey = DebugControlSettingsPolicy.persistKey(key) else { return }
        let defaults = UserDefaults.standard
        let domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(
            DebugControlSettingsPolicy.applying(value, persistKey: persistKey, intoArgumentDomain: domain),
            forName: UserDefaults.argumentDomain
        )
        switch key {
        case "show_in_dock":
            NotificationCenter.default.post(name: .dockVisibilityPreferencesDidChange, object: nil)
        case "auto_detect_calls":
            NotificationCenter.default.post(name: .autoCallDetectionPrefsDidChange, object: nil)
        case "people_in_room":
            NotificationCenter.default.post(name: .localSpeakerPrefsDidChange, object: nil)
        default:
            break
        }
    }

    private func openScreen(_ screen: String, appDelegate: TranscriptedAppDelegate) {
        switch screen {
        case "onboarding":
            appDelegate.onboardingWindowController.present(entrypoint: "debug_control")
        case "menubar":
            if let button = appDelegate.statusItem?.button, let popover = appDelegate.popover, !popover.isShown {
                appDelegate.showMainPopover(relativeTo: button, popover: popover, entrypoint: "debug_control")
            }
        case "today":
            appDelegate.showSettingsWindow(page: .today, source: "debug_control")
        case "home":
            appDelegate.showSettingsWindow(page: .home, source: "debug_control")
        case "dictations":
            appDelegate.showSettingsWindow(page: .dictations, source: "debug_control")
        case "writing":
            appDelegate.showSettingsWindow(page: .writing, source: "debug_control")
        case "general":
            appDelegate.showSettingsWindow(page: .general, source: "debug_control")
        case "people":
            appDelegate.showSettingsWindow(page: .people, source: "debug_control")
        case "connect_agent":
            appDelegate.showSettingsWindow(page: .connectAgent, source: "debug_control")
        default:
            break
        }
    }
}

@MainActor
final class DebugControlPasteTargetWindow {
    static let automationID = "transcripted.debug.paste-target.field"

    private var panel: NSPanel?
    private var textView: NSTextView?

    var isOpen: Bool { panel?.isVisible == true }

    func open() {
        if panel == nil { build() }
        panel?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Transcripted paste target"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.sharingType = .none
        panel.identifier = NSUserInterfaceItemIdentifier("transcripted.debug.paste-target.window")

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: 448, height: 188))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.contentView.bounds)
        textView.isEditable = true
        textView.isRichText = false
        textView.identifier = NSUserInterfaceItemIdentifier(Self.automationID)
        textView.setAccessibilityIdentifier(Self.automationID)
        scroll.documentView = textView
        panel.contentView?.addSubview(scroll)

        self.panel = panel
        self.textView = textView
    }
}

#endif

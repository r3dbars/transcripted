// LabControlChannel.swift
// File-drop control channel that lets a local experiment harness drive the
// real running app (start/stop dictation, start/stop a meeting, import an
// audio file, read status) so the hill-climb lab can time the real app, not
// just benches. Protocol and safety model: docs/lab-control-channel.md.
//
// Safety:
// - OFF unless the process was launched with TRANSCRIPTED_LAB_CONTROL_DIR set
//   to an absolute path. There is no UI toggle and no persisted setting; a
//   normal Finder/Dock launch never has the variable, so it can never turn on.
// - Commands reuse the same app entry points the menus use
//   (TranscriptedAppDelegate.menuStartDictation, the quick menu's
//   stopDictationAndPaste(trigger: .menu), and the menu-bar panel's meeting
//   start/stop calls). This file adds no new capture behavior.
// - Nothing here reports to Sentry, PostHog, or events.jsonl. Timings come
//   from the app's own events.jsonl lines, which the lab reads directly.
// - Everything runs on the main actor from a 250 ms polling task. Nothing
//   touches audio threads.
//
// Pure parsing/validation lives in LabControlCommand.swift (fast-tested).

import Foundation

@MainActor
final class LabControlChannel {
    static let environmentKey = "TRANSCRIPTED_LAB_CONTROL_DIR"
    private static let pollIntervalNanoseconds: UInt64 = 250_000_000
    /// Keeps the one channel alive for the process lifetime, so the app
    /// delegate needs no stored property for it.
    private static var active: LabControlChannel?

    private weak var appDelegate: TranscriptedAppDelegate?
    private let inboxURL: URL
    private let doneURL: URL
    private let responsesURL: URL
    private var pollTask: Task<Void, Never>?
    /// Files that could be neither moved to done/ nor deleted. Skipped so a
    /// stuck file is answered once instead of on every poll.
    private var unmovableFileNames: Set<String> = []
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init(rootURL: URL, appDelegate: TranscriptedAppDelegate) {
        self.appDelegate = appDelegate
        self.inboxURL = rootURL.appendingPathComponent("inbox", isDirectory: true)
        self.doneURL = rootURL.appendingPathComponent("done", isDirectory: true)
        self.responsesURL = rootURL.appendingPathComponent("responses.jsonl", isDirectory: false)
    }

    /// Launch hook. Does nothing unless the environment variable names an
    /// absolute directory.
    static func startIfRequested(
        appDelegate: TranscriptedAppDelegate,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard active == nil else { return }
        let rawValue = environment[environmentKey]
        guard let rootURL = LabControlCommandParser.controlDirectoryURL(fromEnvironmentValue: rawValue) else {
            if rawValue != nil {
                fputs("LAB_CONTROL | ignored: \(environmentKey) must be an absolute path\n", stderr)
            }
            return
        }
        let channel = LabControlChannel(rootURL: rootURL, appDelegate: appDelegate)
        guard channel.prepareDirectories() else {
            fputs("LAB_CONTROL | disabled: could not create inbox/ and done/ under the control directory\n", stderr)
            return
        }
        active = channel
        channel.startPolling()
        fputs("LAB_CONTROL | enabled (pid \(ProcessInfo.processInfo.processIdentifier))\n", stderr)
    }

    private func prepareDirectories() -> Bool {
        let fileManager = FileManager.default
        for url in [inboxURL, doneURL] {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                return false
            }
        }
        return true
    }

    private func startPolling() {
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let channel = self else { return }
                await channel.drainInbox()
                try? await Task.sleep(nanoseconds: LabControlChannel.pollIntervalNanoseconds)
            }
        }
    }

    // MARK: - Inbox

    private func drainInbox() async {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: inboxURL.path)
        } catch {
            return
        }
        let pending = names
            .filter { LabControlCommandParser.isInboxCommandFileName($0) && !unmovableFileNames.contains($0) }
            .sorted()
        // Serial on purpose: a meeting start/stop finishes before the next
        // command runs, so command order in the inbox is execution order.
        for name in pending {
            await process(fileName: name)
        }
    }

    private func process(fileName: String) async {
        let receivedMs = LabControlClock.monotonicMilliseconds()
        let fileURL = inboxURL.appendingPathComponent(fileName, isDirectory: false)

        let parsed: Result<LabControlRequest, LabControlParseFailure>
        switch readCommandFile(at: fileURL) {
        case .success(let data):
            parsed = LabControlCommandParser.parse(data)
        case .failure(let failure):
            parsed = .failure(failure)
        }

        // Move before executing so a command is never run twice, even if
        // executing it takes the app down.
        moveToDone(fileName: fileName, from: fileURL)

        let id: String?
        let command: String?
        let outcome: LabControlOutcome
        switch parsed {
        case .success(let request):
            id = request.id
            command = request.commandName
            outcome = await execute(request.action)
        case .failure(let failure):
            id = failure.id
            command = failure.commandName
            outcome = .failure(failure.error)
        }

        appendResponse(
            LabControlResponse(
                id: id,
                command: command,
                file: LabControlCommandParser.echoableFileName(fileName),
                outcome: outcome,
                at: isoFormatter.string(from: Date()),
                receivedMonotonicMs: receivedMs,
                monotonicMs: LabControlClock.monotonicMilliseconds()
            )
        )
    }

    /// Reads at most `maxCommandBytes + 1` bytes from a regular file. FIFOs,
    /// sockets, directories, and symlinks are refused so a stray inbox entry
    /// can never block the main thread.
    private func readCommandFile(at url: URL) -> Result<Data, LabControlParseFailure> {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileType = attributes?[.type] as? FileAttributeType, fileType == .typeRegular else {
            return .failure(LabControlParseFailure(id: nil, commandName: nil, error: "not_a_regular_file"))
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: LabControlCommandParser.maxCommandBytes + 1) ?? Data()
            return .success(data)
        } catch {
            return .failure(LabControlParseFailure(id: nil, commandName: nil, error: "unreadable_file"))
        }
    }

    private func moveToDone(fileName: String, from fileURL: URL) {
        let fileManager = FileManager.default
        let destination = doneURL.appendingPathComponent(fileName, isDirectory: false)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        if (try? fileManager.moveItem(at: fileURL, to: destination)) != nil {
            return
        }
        if (try? fileManager.removeItem(at: fileURL)) != nil {
            return
        }
        unmovableFileNames.insert(fileName)
    }

    private func appendResponse(_ response: LabControlResponse) {
        guard let line = response.jsonLine() else { return }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: responsesURL.path) {
            _ = fileManager.createFile(
                atPath: responsesURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        guard let handle = try? FileHandle(forWritingTo: responsesURL) else { return }
        LockedFileAppender.append(line, to: handle)
        try? handle.close()
    }

    // MARK: - Commands

    private func execute(_ action: LabControlAction) async -> LabControlOutcome {
        guard let appDelegate else { return .failure("app_unavailable") }
        let meetingSession = appDelegate.appState.meetingSession

        switch action {
        case .ping:
            return .success(["pid": Int(ProcessInfo.processInfo.processIdentifier)])

        case .status:
            return .success(statusSnapshot(appDelegate))

        case .startDictation:
            guard !appDelegate.sessionController.isDictating else {
                return .failure("dictation_already_active")
            }
            // Same entry point as Capture > Start Dictation (Cmd-D).
            appDelegate.menuStartDictation()
            guard appDelegate.sessionController.isDictating else {
                return .failure("dictation_not_started")
            }
            return .success(statusSnapshot(appDelegate))

        case .stopDictation(let paste):
            guard appDelegate.sessionController.isDictating else {
                return .failure("dictation_not_active")
            }
            // Same call the status-item quick menu's Stop Dictation makes.
            appDelegate.sessionController.stopDictationAndPaste(trigger: .menu, autoPaste: paste)
            return .success(nil)

        case .startMeeting:
            if let rejection = LabControlMeetingPolicy.startRejection(meetingSession.state) {
                return .failure(rejection)
            }
            // Same call the menu-bar panel's Record Meeting button makes.
            let started = await meetingSession.startRecording(trigger: .menu)
            return started
                ? LabControlOutcome.success(statusSnapshot(appDelegate))
                : LabControlOutcome.failure("meeting_not_started")

        case .stopMeeting:
            guard let plan = LabControlMeetingPolicy.stopPlan(meetingSession.state) else {
                return .failure("meeting_not_recording")
            }
            // Same calls the menu-bar panel's Stop button makes.
            switch plan {
            case .joinPendingStartThenStop:
                await meetingSession.stopRecordingJoiningPendingStart(reason: .menuBarStopButton)
            case .stop:
                await meetingSession.stopRecording(reason: .menuBarStopButton)
            }
            return .success(statusSnapshot(appDelegate))

        case .importAudio(let path):
            if let rejection = LabControlMeetingPolicy.importRejection(meetingSession.state) {
                return .failure(rejection)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return .failure("file_not_found")
            }
            // Same call Capture > Transcribe Audio File… makes once its open
            // panel returns a URL (the panel itself is skipped).
            let started = await meetingSession.importAudioFile(from: URL(fileURLWithPath: path))
            return started
                ? LabControlOutcome.success(statusSnapshot(appDelegate))
                : LabControlOutcome.failure("import_not_started")
        }
    }

    /// Booleans, a pid, and state names only — no text, titles, or paths.
    private func statusSnapshot(_ appDelegate: TranscriptedAppDelegate) -> [String: Any] {
        let appState = appDelegate.appState
        let meetingState = appState.meetingSession.state
        return [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "dictation_active": appDelegate.sessionController.isDictating,
            "stt_recording": appState.sttRouter.isRecording,
            "stt_transcribing": appState.sttRouter.isTranscribing,
            "stt_model_loaded": appState.sttRouter.isModelLoaded,
            "meeting_state": LabControlMeetingPolicy.stateName(meetingState),
            "meeting_capture_active": LabControlMeetingPolicy.isCaptureActive(meetingState),
        ]
    }
}

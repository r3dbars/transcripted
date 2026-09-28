// LabControlChannel.swift
// File-drop control channel that lets a local experiment harness drive the
// real running app (start/stop dictation, start/stop a meeting, import an
// audio file, read status) so the hill-climb lab can time the real app, not
// just benches. Protocol and safety model: docs/lab-control-channel.md.
//
// Safety:
// - LAB BUILDS ONLY. This whole file, and the one launch hook in
//   TranscriptedApp.swift, sit behind `#if TRANSCRIPTED_LAB_CONTROL`, which
//   only `build.sh --lab` sets. build-beta.sh refuses to run with the lab flag
//   and fails if the env var name below shows up in the shipped binary. In a
//   release build the channel does not exist, because a launch env var is not
//   a trust boundary for a hardened app holding mic, system-audio, and
//   Accessibility grants (anyone can `launchctl setenv` or `open -n --env`).
// - Even in a lab build it stays OFF unless the process was launched with
//   the env var set to an absolute path, and it refuses to start unless the
//   control dir, inbox/, and done/ are real directories (not symlinks) owned
//   by this uid with mode 0700, and responses.jsonl (if present) is a regular
//   file owned by this uid. The layout is re-checked on every poll.
// - Command files are opened O_NOFOLLOW|O_NONBLOCK and checked with fstat
//   (regular, ours, <= 64 KB) before reading, so a symlink or FIFO can neither
//   redirect the read nor block the main thread. Processed files move with
//   rename(2), which never follows a symlink, and nothing is ever deleted
//   outside inbox/.
// - start_dictation calls the dictation session directly with no source app,
//   so, unlike the menu command, it never brings another app to the front.
//   stop_dictation only pastes when the command explicitly says paste: true.
// - Nothing here reports to Sentry, PostHog, or events.jsonl. Timings come
//   from the app's own events.jsonl lines, which the lab reads directly.
// - Everything runs on the main actor from a 250 ms polling task. Nothing
//   touches audio threads.
//
// Pure parsing/validation lives in LabControlCommand.swift (fast-tested).

#if TRANSCRIPTED_LAB_CONTROL

import AppKit
import Darwin
import Foundation

@MainActor
final class LabControlChannel {
    static let environmentKey = "TRANSCRIPTED_LAB_CONTROL_DIR"
    private static let pollIntervalNanoseconds: UInt64 = 250_000_000
    /// Keeps the one channel alive for the process lifetime, so the app
    /// delegate needs no stored property for it.
    private static var active: LabControlChannel?

    private weak var appDelegate: TranscriptedAppDelegate?
    private let rootPath: String
    private let inboxURL: URL
    private let doneURL: URL
    private let responsesPath: String
    private var pollTask: Task<Void, Never>?
    /// Files that could be neither moved to done/ nor unlinked. Skipped so a
    /// stuck file is answered once instead of on every poll.
    private var unmovableFileNames: Set<String> = []
    private var didWarnAboutResponsesFile = false
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
    }

    /// Launch hook. Does nothing unless the environment variable names an
    /// absolute directory that passes the ownership/permission checks.
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
        if let refusal = channel.prepareDirectories() {
            fputs("LAB_CONTROL | disabled: \(refusal) (control dir, inbox/, done/ must be real 0700 dirs you own)\n", stderr)
            return
        }
        active = channel
        channel.startPolling()
        fputs("LAB_CONTROL | enabled (pid \(ProcessInfo.processInfo.processIdentifier))\n", stderr)
    }

    // MARK: - Directory checks

    private enum PathStatus {
        case missing
        case present(mode: UInt32, ownerUID: UInt32)
        case failed(Int32)
    }

    /// lstat(2): describes the path itself, never a symlink's target.
    private static func pathStatus(_ path: String) -> PathStatus {
        var info = stat()
        if lstat(path, &info) == 0 {
            return .present(mode: UInt32(info.st_mode), ownerUID: UInt32(info.st_uid))
        }
        let code = errno
        return code == ENOENT ? .missing : .failed(code)
    }

    private static var currentUID: UInt32 {
        UInt32(getuid())
    }

    /// nil when `path` is (or was just created as) a private directory.
    /// Creates only the last component (mode 0700); never chmods or chowns
    /// something that already exists.
    private static func ensurePrivateDirectory(_ path: String, label: String) -> String? {
        switch pathStatus(path) {
        case .missing:
            if mkdir(path, 0o700) != 0 {
                return "\(label) could not be created (errno \(errno))"
            }
        case .failed(let code):
            return "\(label) could not be checked (errno \(code))"
        case .present:
            break
        }
        return privateDirectoryRefusal(path, label: label)
    }

    private static func privateDirectoryRefusal(_ path: String, label: String) -> String? {
        guard case .present(let mode, let ownerUID) = pathStatus(path) else {
            return "\(label) is missing"
        }
        if let refusal = LabControlFilePolicy.directoryRefusal(mode: mode, ownerUID: ownerUID, currentUID: currentUID) {
            return "\(label) \(refusal)"
        }
        return nil
    }

    private static func responsesFileRefusal(_ path: String) -> String? {
        switch pathStatus(path) {
        case .missing:
            return nil
        case .failed(let code):
            return "responses.jsonl could not be checked (errno \(code))"
        case .present(let mode, let ownerUID):
            if let refusal = LabControlFilePolicy.responsesFileRefusal(mode: mode, ownerUID: ownerUID, currentUID: currentUID) {
                return "responses.jsonl \(refusal)"
            }
            return nil
        }
    }

    /// nil when the channel may start; otherwise one short reason.
    private func prepareDirectories() -> String? {
        if let refusal = Self.ensurePrivateDirectory(rootPath, label: "control dir") {
            return refusal
        }
        if let refusal = Self.ensurePrivateDirectory(inboxURL.path, label: "inbox/") {
            return refusal
        }
        if let refusal = Self.ensurePrivateDirectory(doneURL.path, label: "done/") {
            return refusal
        }
        return Self.responsesFileRefusal(responsesPath)
    }

    /// Re-run every poll: if anything was swapped since launch, stop.
    private func layoutRefusal() -> String? {
        if let refusal = Self.privateDirectoryRefusal(rootPath, label: "control dir") {
            return refusal
        }
        if let refusal = Self.privateDirectoryRefusal(inboxURL.path, label: "inbox/") {
            return refusal
        }
        if let refusal = Self.privateDirectoryRefusal(doneURL.path, label: "done/") {
            return refusal
        }
        return Self.responsesFileRefusal(responsesPath)
    }

    private func startPolling() {
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let channel = self else { return }
                if let refusal = channel.layoutRefusal() {
                    fputs("LAB_CONTROL | stopped: \(refusal)\n", stderr)
                    return
                }
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
        let filePath = inboxURL.appendingPathComponent(fileName, isDirectory: false).path

        let parsed: Result<LabControlRequest, LabControlParseFailure>
        switch readCommandFile(atPath: filePath) {
        case .success(let data):
            parsed = LabControlCommandParser.parse(data)
        case .failure(let failure):
            parsed = .failure(failure)
        }

        // Move before executing so a command is never run twice, even if
        // executing it takes the app down.
        moveToDone(fileName: fileName, fromPath: filePath)

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

    /// Opens with O_NOFOLLOW|O_NONBLOCK (a symlink fails with ELOOP, a FIFO
    /// opens without blocking), then decides from fstat on the open fd, so
    /// there is no check-then-open race. Reads at most `maxCommandBytes + 1`.
    private func readCommandFile(atPath path: String) -> Result<Data, LabControlParseFailure> {
        func failure(_ error: String) -> Result<Data, LabControlParseFailure> {
            .failure(LabControlParseFailure(id: nil, commandName: nil, error: error))
        }

        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            return failure(errno == ELOOP ? "not_a_regular_file" : "unreadable_file")
        }
        defer { _ = close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { return failure("unreadable_file") }
        if let refusal = LabControlFilePolicy.commandFileRefusal(
            mode: UInt32(info.st_mode),
            ownerUID: UInt32(info.st_uid),
            currentUID: Self.currentUID,
            size: Int64(info.st_size)
        ) {
            return failure(refusal)
        }

        let limit = LabControlCommandParser.maxCommandBytes + 1
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < limit {
            let wanted = min(buffer.count, limit - data.count)
            let count: Int = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, wanted)
            }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return failure("unreadable_file")
            }
        }
        return .success(data)
    }

    /// rename(2) acts on the directory entry itself (it never follows a
    /// symlink in either last component) and atomically replaces a same-named
    /// entry inside done/, which was verified as a real 0700 directory. If the
    /// move fails, only the inbox entry is unlinked. Nothing outside inbox/
    /// and done/ can be touched.
    private func moveToDone(fileName: String, fromPath sourcePath: String) {
        let destinationPath = doneURL.appendingPathComponent(fileName, isDirectory: false).path
        if rename(sourcePath, destinationPath) == 0 {
            return
        }
        if unlink(sourcePath) == 0 {
            return
        }
        unmovableFileNames.insert(fileName)
    }

    private func appendResponse(_ response: LabControlResponse) {
        guard let line = response.jsonLine() else { return }
        let fd = open(responsesPath, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            warnAboutResponsesFileOnce("could not open responses.jsonl (errno \(errno))")
            return
        }
        defer { _ = close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            warnAboutResponsesFileOnce("could not check responses.jsonl")
            return
        }
        if let refusal = LabControlFilePolicy.responsesFileRefusal(
            mode: UInt32(info.st_mode),
            ownerUID: UInt32(info.st_uid),
            currentUID: Self.currentUID
        ) {
            warnAboutResponsesFileOnce("responses.jsonl \(refusal)")
            return
        }
        // The fd stays owned by this function (closed by the defer above).
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        LockedFileAppender.append(line, to: handle)
    }

    private func warnAboutResponsesFileOnce(_ message: String) {
        guard !didWarnAboutResponsesFile else { return }
        didWarnAboutResponsesFile = true
        fputs("LAB_CONTROL | not writing responses: \(message)\n", stderr)
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
            // The same session call Capture > Start Dictation (Cmd-D) ends in
            // (TranscriptedAppDelegate.startDictationFromSettings), minus its
            // `resolvedSourceApp()?.activate` step: with no source app nothing
            // is brought to the front and there is no captured paste target.
            // `sessionController` is the same instance the menu path reaches
            // through appState.contextCapture.sessionController.
            appDelegate.sessionController.startDictation(sourceApp: nil, trigger: .menu)
            guard appDelegate.sessionController.isDictating else {
                return .failure("dictation_not_started")
            }
            return .success(statusSnapshot(appDelegate))

        case .stopDictation(let paste):
            guard appDelegate.sessionController.isDictating else {
                return .failure("dictation_not_active")
            }
            // Same call the status-item quick menu's Stop Dictation makes.
            // `paste` is false unless the command explicitly asked for it.
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

#endif

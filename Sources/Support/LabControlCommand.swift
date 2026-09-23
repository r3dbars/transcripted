// LabControlCommand.swift
// Pure parsing, validation, and response encoding for the lab control
// channel (see LabControlChannel.swift for the runtime side and
// docs/lab-control-channel.md for the protocol).
//
// Deliberately Foundation-only (plus the dependency-free MeetingSessionState)
// and free of app state, AppKit, and file I/O, so the fast-test runner can
// cover every accept/reject decision without compiling the app. Nothing in
// this file is ever sent off-device.

import Foundation

/// The commands the lab channel accepts, by wire name.
enum LabControlCommandName: String, CaseIterable {
    case ping
    case status
    case startDictation = "start_dictation"
    case stopDictation = "stop_dictation"
    case startMeeting = "start_meeting"
    case stopMeeting = "stop_meeting"
    case importAudio = "import_audio"
}

/// A validated command, with its arguments already checked.
enum LabControlAction: Equatable {
    case ping
    case status
    case startDictation
    /// `paste: false` maps to `stopDictationAndPaste(autoPaste: false)`: the
    /// transcript is still transcribed and saved, but nothing is pasted.
    case stopDictation(paste: Bool)
    case startMeeting
    case stopMeeting
    /// Absolute path to an existing audio/video file.
    case importAudio(path: String)
}

struct LabControlRequest: Equatable {
    let id: String
    let commandName: String
    let action: LabControlAction
}

/// A command file that could not be accepted. `id` and `commandName` are
/// whatever could be safely recovered, so the lab can still match the
/// response line; both are nil when the file was not usable JSON.
struct LabControlParseFailure: Error, Equatable {
    let id: String?
    let commandName: String?
    let error: String
}

/// What executing a command produced. `result` holds only booleans, numbers,
/// and short state names — never transcript text or user file paths.
struct LabControlOutcome {
    let ok: Bool
    let error: String?
    let result: [String: Any]?

    static func success(_ result: [String: Any]? = nil) -> LabControlOutcome {
        LabControlOutcome(ok: true, error: nil, result: result)
    }

    static func failure(_ error: String) -> LabControlOutcome {
        LabControlOutcome(ok: false, error: error, result: nil)
    }
}

enum LabControlCommandParser {
    static let maxCommandBytes = 64 * 1024
    static let maxIDLength = 128
    static let maxFileNameLength = 200
    static let maxPathLength = 4096

    private static let idScalars: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "._:-")
        return set
    }()

    private static let wordScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")

    /// The control directory named by `TRANSCRIPTED_LAB_CONTROL_DIR`, or nil
    /// when the variable is missing, blank, or not an absolute path. A nil
    /// result means the channel stays off.
    static func controlDirectoryURL(fromEnvironmentValue rawValue: String?) -> URL? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/"), !trimmed.contains("\u{0}") else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
    }

    /// Only finished `*.json` files are commands. Hidden files and anything
    /// else (for example a client's `*.json.tmp` staging file) are ignored,
    /// so a client that writes then renames is never read half-written.
    static func isInboxCommandFileName(_ name: String) -> Bool {
        guard !name.hasPrefix("."), name.hasSuffix(".json") else { return false }
        return name.count > ".json".count
    }

    /// The inbox file name, echoed back only when it is short and plain.
    static func echoableFileName(_ name: String) -> String? {
        guard !name.isEmpty, name.count <= maxFileNameLength else { return nil }
        return name.unicodeScalars.allSatisfy { idScalars.contains($0) } ? name : nil
    }

    static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= maxIDLength else { return false }
        return id.unicodeScalars.allSatisfy { idScalars.contains($0) }
    }

    /// Lowercase snake_case words up to 64 chars: safe to echo into a response.
    static func isEchoableWord(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { wordScalars.contains($0) }
    }

    /// JSON `true`/`false` only. `JSONSerialization` hands numbers and
    /// booleans back as NSNumber, so `as? Bool` alone would accept `1`.
    static func jsonBool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func parse(_ data: Data) -> Result<LabControlRequest, LabControlParseFailure> {
        guard data.count <= maxCommandBytes else {
            return .failure(LabControlParseFailure(id: nil, commandName: nil, error: "payload_too_large"))
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .failure(LabControlParseFailure(id: nil, commandName: nil, error: "malformed_json"))
        }
        guard let dictionary = object as? [String: Any] else {
            return .failure(LabControlParseFailure(id: nil, commandName: nil, error: "not_an_object"))
        }

        let rawID = dictionary["id"] as? String
        let safeID: String? = rawID.flatMap { isValidID($0) ? $0 : nil }
        let rawCommand = dictionary["command"] as? String
        let safeCommand: String? = rawCommand.flatMap { isEchoableWord($0) ? $0 : nil }

        func fail(_ error: String) -> Result<LabControlRequest, LabControlParseFailure> {
            .failure(LabControlParseFailure(id: safeID, commandName: safeCommand, error: error))
        }

        guard dictionary["id"] != nil else { return fail("missing_id") }
        guard let id = safeID else { return fail("invalid_id") }
        guard dictionary["command"] != nil else { return fail("missing_command") }
        guard let commandString = rawCommand else { return fail("invalid_command") }
        guard let name = LabControlCommandName(rawValue: commandString) else {
            return fail("unknown_command")
        }

        var args: [String: Any] = [:]
        if let rawArgs = dictionary["args"], !(rawArgs is NSNull) {
            guard let argsObject = rawArgs as? [String: Any] else { return fail("invalid_args") }
            args = argsObject
        }

        switch actionFor(name, args: args) {
        case .success(let action):
            return .success(LabControlRequest(id: id, commandName: name.rawValue, action: action))
        case .failure(let failure):
            return fail(failure.error)
        }
    }

    private static func actionFor(
        _ name: LabControlCommandName,
        args: [String: Any]
    ) -> Result<LabControlAction, LabControlParseFailure> {
        func reject(_ error: String) -> Result<LabControlAction, LabControlParseFailure> {
            .failure(LabControlParseFailure(id: nil, commandName: nil, error: error))
        }

        let allowedKeys: Set<String>
        switch name {
        case .stopDictation:
            allowedKeys = ["paste"]
        case .importAudio:
            allowedKeys = ["path"]
        case .ping, .status, .startDictation, .startMeeting, .stopMeeting:
            allowedKeys = []
        }
        if let unknownKey = args.keys.sorted().first(where: { !allowedKeys.contains($0) }) {
            return reject(isEchoableWord(unknownKey) ? "unknown_arg:\(unknownKey)" : "unknown_arg")
        }

        switch name {
        case .ping:
            return .success(.ping)
        case .status:
            return .success(.status)
        case .startDictation:
            return .success(.startDictation)
        case .stopDictation:
            var paste = true
            if let rawPaste = args["paste"] {
                guard let value = jsonBool(rawPaste) else { return reject("invalid_arg:paste") }
                paste = value
            }
            return .success(.stopDictation(paste: paste))
        case .startMeeting:
            return .success(.startMeeting)
        case .stopMeeting:
            return .success(.stopMeeting)
        case .importAudio:
            guard let rawPath = args["path"] else { return reject("missing_arg:path") }
            guard let path = rawPath as? String,
                  path.hasPrefix("/"),
                  path.count <= maxPathLength,
                  !path.contains("\u{0}") else {
                return reject("invalid_arg:path")
            }
            return .success(.importAudio(path: path))
        }
    }
}

/// Meeting-state gates for the lab commands. These mirror the menu-bar
/// panel's start/stop toggle (MenuBarPanelController.startMeetingFromMenu):
/// start only when no capture is active, stop a steady-state recording, and
/// join a pending start before stopping it.
enum LabControlMeetingPolicy {
    enum StopPlan: Equatable {
        case stop
        case joinPendingStartThenStop
    }

    static func stateName(_ state: MeetingSessionState) -> String {
        switch state {
        case .idle: return "idle"
        case .loadingModels: return "loading_models"
        case .ready: return "ready"
        case .startingRecording: return "starting_recording"
        case .recording: return "recording"
        case .stoppingRecording: return "stopping_recording"
        case .transcribing: return "transcribing"
        case .error: return "error"
        }
    }

    static func isCaptureActive(_ state: MeetingSessionState) -> Bool {
        switch state {
        case .startingRecording, .recording, .stoppingRecording:
            return true
        case .idle, .loadingModels, .ready, .transcribing, .error:
            return false
        }
    }

    /// nil when a start may proceed; otherwise the error code to report.
    static func startRejection(_ state: MeetingSessionState) -> String? {
        isCaptureActive(state) ? "meeting_capture_active" : nil
    }

    /// Imports are refused while a capture is active, the same way
    /// `MeetingSessionController.importAudioFile` refuses them.
    static func importRejection(_ state: MeetingSessionState) -> String? {
        isCaptureActive(state) ? "meeting_capture_active" : nil
    }

    /// nil when there is nothing to stop.
    static func stopPlan(_ state: MeetingSessionState) -> StopPlan? {
        switch state {
        case .recording:
            return .stop
        case .startingRecording:
            return .joinPendingStartThenStop
        case .idle, .loadingModels, .ready, .stoppingRecording, .transcribing, .error:
            return nil
        }
    }
}

enum LabControlClock {
    /// Milliseconds on the process uptime clock (mach_absolute_time based,
    /// pauses during sleep). Only differences between two values mean anything.
    static func monotonicMilliseconds(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int {
        Int((uptime * 1000).rounded())
    }
}

/// One line of `<dir>/responses.jsonl`.
struct LabControlResponse {
    let id: String?
    let command: String?
    let file: String?
    let outcome: LabControlOutcome
    /// ISO 8601 wall clock with fractional seconds — the same format as
    /// `events.jsonl` `timestamp`, so the two can be compared directly.
    let at: String
    let receivedMonotonicMs: Int
    let monotonicMs: Int

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "ok": outcome.ok,
            "at": at,
            "received_monotonic_ms": receivedMonotonicMs,
            "monotonic_ms": monotonicMs,
        ]
        if let id {
            object["id"] = id
        } else {
            object["id"] = NSNull()
        }
        if let command {
            object["command"] = command
        } else {
            object["command"] = NSNull()
        }
        if let file {
            object["file"] = file
        }
        if let error = outcome.error {
            object["error"] = error
        }
        if let result = outcome.result {
            object["result"] = result
        }
        return object
    }

    /// A single newline-terminated JSON line, or nil if the payload could not
    /// be encoded (never expected; the caller just skips the line).
    func jsonLine() -> Data? {
        let object = jsonObject()
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        data.append(0x0A)
        return data
    }
}

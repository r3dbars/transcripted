// DebugControlCommand.swift
// Pure parsing, validation, and JSON encoding for the debug-only test
// control surface (see DebugControlChannel.swift for the runtime and
// docs/debug-control-surface.md for the protocol).
//
// Foundation-only and free of AppKit, file I/O, and app state so the
// fast-test runner and the E2E smoke can cover every accept/reject
// decision. Nothing in this file is sent off-device.
//
// This file is compiled into every build (it is inert on its own). It
// must never contain the channel's env-var name as a literal:
// build-beta.sh fails a release build whose binary contains that name.

import Foundation

enum DebugControlSchema {
    static let version = 1
}

/// Wire names the debug surface accepts.
enum DebugControlCommandName: String, CaseIterable {
    case ping
    case state
    case status
    case startDictation = "start_dictation"
    case stopDictation = "stop_dictation"
    case startMeeting = "start_meeting"
    case stopMeeting = "stop_meeting"
    case importAudio = "import_audio"
    case pasteTargetOpen = "paste_target_open"
    case openScreen = "open_screen"
    case settingsGet = "settings_get"
    case settingsSet = "settings_set"

    /// `status` is accepted as an alias of `state`.
    var canonicalName: String {
        self == .status ? DebugControlCommandName.state.rawValue : rawValue
    }
}

enum DebugControlAction: Equatable {
    case ping
    case state
    case startDictation
    case stopDictation(paste: Bool)
    case startMeeting
    case stopMeeting
    case importAudio(path: String)
    case pasteTargetOpen
    case openScreen(screen: String)
    case settingsGet(key: String)
    case settingsSet(key: String, value: Bool)
}

struct DebugControlRequest: Equatable {
    let id: String
    let commandName: String
    let action: DebugControlAction
}

struct DebugControlParseFailure: Error, Equatable {
    let id: String?
    let commandName: String?
    let error: String
}

struct DebugControlOutcome: Equatable {
    let ok: Bool
    let error: String?
    let result: [String: String]

    static func success(_ result: [String: String] = [:]) -> DebugControlOutcome {
        DebugControlOutcome(ok: true, error: nil, result: result)
    }

    static func failure(_ error: String) -> DebugControlOutcome {
        DebugControlOutcome(ok: false, error: error, result: [:])
    }
}

/// In-memory session the tests and E2E smoke drive. Live execution uses the
/// same gates, then calls the real controllers.
struct DebugControlSessionSnapshot: Equatable {
    var dictationActive: Bool
    var meetingState: String
    var openScreen: String
    var pasteTargetOpen: Bool
    var settings: [String: Bool]

    static func idle() -> DebugControlSessionSnapshot {
        DebugControlSessionSnapshot(
            dictationActive: false,
            meetingState: "ready",
            openScreen: "none",
            pasteTargetOpen: false,
            settings: DebugControlSettingsPolicy.defaults
        )
    }
}

enum DebugControlSettingsPolicy {
    static let keys = [
        "show_in_dock",
        "auto_detect_calls",
        "dictation_sounds",
        "cleanup_pasted_text",
        "crash_reports",
        "usage_stats",
        "people_in_room",
        "island_in_screen_sharing",
    ]

    static let defaults: [String: Bool] = [
        "show_in_dock": true,
        "auto_detect_calls": true,
        "dictation_sounds": true,
        "cleanup_pasted_text": true,
        "crash_reports": true,
        "usage_stats": true,
        "people_in_room": false,
        "island_in_screen_sharing": false,
    ]

    static func isAllowedKey(_ key: String) -> Bool {
        keys.contains(key)
    }

    static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return nil
        }
    }

    /// Real `UserDefaults` keys. `settings_set` writes these into the process
    /// argument domain (volatile, not persisted) so the live readers see them
    /// without touching the user's `com.justinbetker.draft` plist.
    static let persistKeys: [String: String] = [
        "show_in_dock": "show-transcripted-in-dock",
        "auto_detect_calls": "auto-call-detection-enabled",
        "dictation_sounds": "enableUISounds",
        "cleanup_pasted_text": "dictationCleanupEnabled",
        "crash_reports": "observability-crash-reporting-enabled",
        "usage_stats": "observability-anonymous-analytics-enabled",
        "people_in_room": "local-speaker-split-enabled",
        "island_in_screen_sharing": "notchIslandVisibleInScreenSharing",
    ]

    static func persistKey(_ key: String) -> String? {
        persistKeys[key]
    }

    /// Merge a setting into a copy of the argument domain. Replacing that
    /// domain without copying would drop launch-arg telemetry overrides.
    static func applying(
        _ value: Bool,
        persistKey: String,
        intoArgumentDomain domain: [String: Any]
    ) -> [String: Any] {
        var next = domain
        next[persistKey] = value
        return next
    }
}

enum DebugControlScreenPolicy {
    static let ids = [
        "today",
        "home",
        "dictations",
        "writing",
        "general",
        "people",
        "connect_agent",
        "onboarding",
        "menubar",
    ]

    static func isAllowed(_ screen: String) -> Bool {
        ids.contains(screen)
    }

    static func settingsPageID(_ screen: String) -> String? {
        switch screen {
        case "today", "home", "dictations", "writing", "general", "people", "connect_agent":
            return screen
        default:
            return nil
        }
    }
}

/// AX identifiers the menu bar already exposes. Kept as strings so this
/// file stays Foundation-only; the fast tests assert they match
/// `MenuBarAutomationID`.
enum DebugControlAutomationIDs {
    static let menuBar: [String: String] = [
        "status_item": "transcripted.status-item.button",
        "start_meeting": "transcripted.menubar.primary.start-meeting",
        "start_dictation": "transcripted.menubar.primary.start-dictation",
        "open_transcripted": "transcripted.menubar.utility.open-transcripted",
        "check_updates": "transcripted.menubar.utility.check-updates",
        "quit": "transcripted.menubar.utility.quit",
        "paste_target_field": "transcripted.debug.paste-target.field",
    ]
}

enum DebugControlAdmission {
    /// nil when the channel may start. `controlDirectory` is the raw env
    /// value the caller already read (this file never names that variable).
    static func refusal(harnessActive: Bool, controlDirectory: String?) -> String? {
        if !harnessActive { return "harness_inactive" }
        guard let controlDirectory else { return "control_dir_required" }
        let trimmed = controlDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/"), !trimmed.contains("\u{0}") else {
            return "control_dir_required"
        }
        return nil
    }
}

enum DebugControlMeetingGate {
    static let captureActiveStates: Set<String> = [
        "starting_recording", "recording", "stopping_recording",
    ]

    static func isCaptureActive(_ state: String) -> Bool {
        captureActiveStates.contains(state)
    }

    static func startRejection(_ state: String) -> String? {
        isCaptureActive(state) ? "meeting_capture_active" : nil
    }

    static func importRejection(_ state: String) -> String? {
        isCaptureActive(state) ? "meeting_capture_active" : nil
    }

    static func stopRejection(_ state: String) -> String? {
        switch state {
        case "recording", "starting_recording":
            return nil
        default:
            return "meeting_not_recording"
        }
    }
}

/// `startDictation` returns once `isDictating` is true while the mic/STT
/// graph is still coming up. `stopDictationAndPaste` returns before
/// `isDictating` flips. The channel waits on these predicates (20 ms
/// polls, 2 s cap) and then snapshots live state. A timeout still
/// returns `ok: true` with the latest flags.
enum DebugControlSettlePolicy {
    static let timeoutMilliseconds = 2_000
    static let pollMilliseconds = 20

    static func startedSettled(dictationActive: Bool, sttRecording: Bool) -> Bool {
        dictationActive && sttRecording
    }

    static func stoppedSettled(dictationActive: Bool) -> Bool {
        !dictationActive
    }

    static func shouldKeepWaiting(elapsedMilliseconds: Int, settled: Bool) -> Bool {
        !settled && elapsedMilliseconds < timeoutMilliseconds
    }
}

enum DebugControlSessionPolicy {
    static func apply(
        _ action: DebugControlAction,
        to snapshot: DebugControlSessionSnapshot
    ) -> Result<DebugControlSessionSnapshot, String> {
        var next = snapshot
        switch action {
        case .ping, .state:
            return .success(next)
        case .startDictation:
            if next.dictationActive { return .failure("dictation_already_active") }
            next.dictationActive = true
            return .success(next)
        case .stopDictation:
            if !next.dictationActive { return .failure("dictation_not_active") }
            next.dictationActive = false
            return .success(next)
        case .startMeeting:
            if let rejection = DebugControlMeetingGate.startRejection(next.meetingState) {
                return .failure(rejection)
            }
            next.meetingState = "recording"
            return .success(next)
        case .stopMeeting:
            if let rejection = DebugControlMeetingGate.stopRejection(next.meetingState) {
                return .failure(rejection)
            }
            next.meetingState = "transcribing"
            return .success(next)
        case .importAudio:
            if let rejection = DebugControlMeetingGate.importRejection(next.meetingState) {
                return .failure(rejection)
            }
            return .success(next)
        case .pasteTargetOpen:
            next.pasteTargetOpen = true
            return .success(next)
        case .openScreen(let screen):
            guard DebugControlScreenPolicy.isAllowed(screen) else {
                return .failure("invalid_arg:screen")
            }
            next.openScreen = screen
            return .success(next)
        case .settingsGet(let key):
            guard DebugControlSettingsPolicy.isAllowedKey(key) else {
                return .failure("unknown_setting")
            }
            return .success(next)
        case .settingsSet(let key, let value):
            guard DebugControlSettingsPolicy.isAllowedKey(key) else {
                return .failure("unknown_setting")
            }
            next.settings[key] = value
            return .success(next)
        }
    }
}

enum DebugControlStateCodec {
    static func encode(_ snapshot: DebugControlSessionSnapshot, pid: Int) -> [String: Any] {
        var settings: [String: Any] = [:]
        for key in DebugControlSettingsPolicy.keys {
            settings[key] = snapshot.settings[key] ?? DebugControlSettingsPolicy.defaults[key] ?? false
        }
        return [
            "schema_version": DebugControlSchema.version,
            "pid": pid,
            "harness_active": true,
            "dictation_active": snapshot.dictationActive,
            "meeting_state": snapshot.meetingState,
            "meeting_capture_active": DebugControlMeetingGate.isCaptureActive(snapshot.meetingState),
            "open_screen": snapshot.openScreen,
            "paste_target_open": snapshot.pasteTargetOpen,
            "settings": settings,
            "automation_ids": DebugControlAutomationIDs.menuBar,
        ]
    }

    static func requiredStateKeys() -> [String] {
        [
            "schema_version",
            "pid",
            "harness_active",
            "dictation_active",
            "meeting_state",
            "meeting_capture_active",
            "open_screen",
            "paste_target_open",
            "settings",
            "automation_ids",
        ]
    }
}

enum DebugControlCommandParser {
    static let maxCommandBytes = 64 * 1024
    static let maxIDLength = 128
    static let maxFileNameLength = 200
    static let maxPathLength = 4096
    static let urlScheme = "transcripted-debug"

    private static let idScalars: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "._:-")
        return set
    }()

    private static let wordScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")

    static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= maxIDLength else { return false }
        return id.unicodeScalars.allSatisfy { idScalars.contains($0) }
    }

    static func isEchoableWord(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { wordScalars.contains($0) }
    }

    static func jsonBool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func parse(_ data: Data) -> Result<DebugControlRequest, DebugControlParseFailure> {
        guard data.count <= maxCommandBytes else {
            return .failure(DebugControlParseFailure(id: nil, commandName: nil, error: "payload_too_large"))
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .failure(DebugControlParseFailure(id: nil, commandName: nil, error: "malformed_json"))
        }
        guard let dictionary = object as? [String: Any] else {
            return .failure(DebugControlParseFailure(id: nil, commandName: nil, error: "not_an_object"))
        }
        return parseDictionary(dictionary)
    }

    static func parseDictionary(_ dictionary: [String: Any]) -> Result<DebugControlRequest, DebugControlParseFailure> {
        let rawID = dictionary["id"] as? String
        let safeID: String? = rawID.flatMap { isValidID($0) ? $0 : nil }
        let rawCommand = dictionary["command"] as? String
        let safeCommand: String? = rawCommand.flatMap { isEchoableWord($0) ? $0 : nil }

        func fail(_ error: String) -> Result<DebugControlRequest, DebugControlParseFailure> {
            .failure(DebugControlParseFailure(id: safeID, commandName: safeCommand, error: error))
        }

        guard dictionary["id"] != nil else { return fail("missing_id") }
        guard let id = safeID else { return fail("invalid_id") }
        guard dictionary["command"] != nil else { return fail("missing_command") }
        guard let commandString = rawCommand else { return fail("invalid_command") }
        guard let name = DebugControlCommandName(rawValue: commandString) else {
            return fail("unknown_command")
        }

        var args: [String: Any] = [:]
        if let rawArgs = dictionary["args"], !(rawArgs is NSNull) {
            guard let argsObject = rawArgs as? [String: Any] else { return fail("invalid_args") }
            args = argsObject
        }

        switch actionFor(name, args: args) {
        case .success(let action):
            return .success(DebugControlRequest(id: id, commandName: name.canonicalName, action: action))
        case .failure(let failure):
            return fail(failure.error)
        }
    }

    static func parseArgv(_ argv: [String], id: String = "cli") -> Result<DebugControlRequest, DebugControlParseFailure> {
        guard isValidID(id) else {
            return .failure(DebugControlParseFailure(id: nil, commandName: nil, error: "invalid_id"))
        }
        guard let first = argv.first else {
            return .failure(DebugControlParseFailure(id: id, commandName: nil, error: "missing_command"))
        }

        func request(_ name: DebugControlCommandName, args: [String: Any] = [:]) -> Result<DebugControlRequest, DebugControlParseFailure> {
            parseDictionary(["id": id, "command": name.rawValue, "args": args])
        }

        switch first {
        case "state", "status", "ping":
            guard argv.count == 1 else {
                return .failure(DebugControlParseFailure(id: id, commandName: first, error: "unknown_arg"))
            }
            return request(DebugControlCommandName(rawValue: first) ?? .state)
        case "dictation":
            guard argv.count >= 2 else {
                return .failure(DebugControlParseFailure(id: id, commandName: nil, error: "missing_command"))
            }
            switch argv[1] {
            case "start":
                guard argv.count == 2 else {
                    return .failure(DebugControlParseFailure(id: id, commandName: "start_dictation", error: "unknown_arg"))
                }
                return request(.startDictation)
            case "stop":
                var paste = false
                if argv.count == 3 {
                    guard argv[2] == "--paste" else {
                        return .failure(DebugControlParseFailure(id: id, commandName: "stop_dictation", error: "unknown_arg"))
                    }
                    paste = true
                } else if argv.count != 2 {
                    return .failure(DebugControlParseFailure(id: id, commandName: "stop_dictation", error: "unknown_arg"))
                }
                return request(.stopDictation, args: ["paste": paste])
            default:
                return .failure(DebugControlParseFailure(id: id, commandName: nil, error: "unknown_command"))
            }
        case "meeting":
            guard argv.count == 2 else {
                return .failure(DebugControlParseFailure(id: id, commandName: nil, error: "unknown_arg"))
            }
            switch argv[1] {
            case "start": return request(.startMeeting)
            case "stop": return request(.stopMeeting)
            default:
                return .failure(DebugControlParseFailure(id: id, commandName: nil, error: "unknown_command"))
            }
        case "import":
            guard argv.count == 2 else {
                return .failure(DebugControlParseFailure(id: id, commandName: "import_audio", error: argv.count < 2 ? "missing_arg:path" : "unknown_arg"))
            }
            return request(.importAudio, args: ["path": argv[1]])
        case "paste-target":
            guard argv.count == 2, argv[1] == "open" else {
                return .failure(DebugControlParseFailure(id: id, commandName: nil, error: "unknown_command"))
            }
            return request(.pasteTargetOpen)
        case "open":
            guard argv.count == 2 else {
                return .failure(DebugControlParseFailure(id: id, commandName: "open_screen", error: argv.count < 2 ? "missing_arg:screen" : "unknown_arg"))
            }
            return request(.openScreen, args: ["screen": argv[1]])
        case "settings":
            guard argv.count >= 3 else {
                return .failure(DebugControlParseFailure(id: id, commandName: nil, error: "missing_command"))
            }
            switch argv[1] {
            case "get":
                guard argv.count == 3 else {
                    return .failure(DebugControlParseFailure(id: id, commandName: "settings_get", error: "unknown_arg"))
                }
                return request(.settingsGet, args: ["key": argv[2]])
            case "set":
                guard argv.count == 4 else {
                    return .failure(DebugControlParseFailure(
                        id: id,
                        commandName: "settings_set",
                        error: argv.count < 4 ? "missing_arg:value" : "unknown_arg"
                    ))
                }
                return request(.settingsSet, args: ["key": argv[2], "value": argv[3]])
            default:
                return .failure(DebugControlParseFailure(id: id, commandName: nil, error: "unknown_command"))
            }
        default:
            if first.hasPrefix("\(urlScheme):") {
                return parseURLString(first, id: id)
            }
            return .failure(DebugControlParseFailure(id: id, commandName: isEchoableWord(first) ? first : nil, error: "unknown_command"))
        }
    }

    static func parseURLString(_ raw: String, id: String = "url") -> Result<DebugControlRequest, DebugControlParseFailure> {
        guard let url = URL(string: raw) else {
            return .failure(DebugControlParseFailure(id: id, commandName: nil, error: "malformed_url"))
        }
        return parseURL(url, id: id)
    }

    static func parseURL(_ url: URL, id: String = "url") -> Result<DebugControlRequest, DebugControlParseFailure> {
        guard url.scheme == urlScheme else {
            return .failure(DebugControlParseFailure(id: id, commandName: nil, error: "unknown_scheme"))
        }
        let host = url.host ?? ""
        let pathParts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var parts = [host].filter { !$0.isEmpty } + pathParts
        if parts.isEmpty, let hostless = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").first {
            parts = [String(hostless)]
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func queryValue(_ name: String) -> String? {
            query.first(where: { $0.name == name })?.value
        }

        let requestID = queryValue("id").flatMap { isValidID($0) ? $0 : nil } ?? id
        func request(_ name: DebugControlCommandName, args: [String: Any] = [:]) -> Result<DebugControlRequest, DebugControlParseFailure> {
            parseDictionary(["id": requestID, "command": name.rawValue, "args": args])
        }

        switch parts {
        case ["state"], ["status"], ["ping"]:
            return request(DebugControlCommandName(rawValue: parts[0]) ?? .state)
        case ["dictation", "start"]:
            return request(.startDictation)
        case ["dictation", "stop"]:
            var paste = false
            if let rawPaste = queryValue("paste") {
                guard let value = DebugControlSettingsPolicy.parseBool(rawPaste) else {
                    return .failure(DebugControlParseFailure(id: requestID, commandName: "stop_dictation", error: "invalid_arg:paste"))
                }
                paste = value
            }
            return request(.stopDictation, args: ["paste": paste])
        case ["meeting", "start"]:
            return request(.startMeeting)
        case ["meeting", "stop"]:
            return request(.stopMeeting)
        case ["import"]:
            guard let path = queryValue("path") else {
                return .failure(DebugControlParseFailure(id: requestID, commandName: "import_audio", error: "missing_arg:path"))
            }
            return request(.importAudio, args: ["path": path])
        case ["paste-target", "open"], ["paste_target", "open"]:
            return request(.pasteTargetOpen)
        case ["open"]:
            guard let screen = queryValue("screen") else {
                return .failure(DebugControlParseFailure(id: requestID, commandName: "open_screen", error: "missing_arg:screen"))
            }
            return request(.openScreen, args: ["screen": screen])
        case ["settings", "get"]:
            guard let key = queryValue("key") else {
                return .failure(DebugControlParseFailure(id: requestID, commandName: "settings_get", error: "missing_arg:key"))
            }
            return request(.settingsGet, args: ["key": key])
        case ["settings", "set"]:
            guard let key = queryValue("key") else {
                return .failure(DebugControlParseFailure(id: requestID, commandName: "settings_set", error: "missing_arg:key"))
            }
            guard let value = queryValue("value") else {
                return .failure(DebugControlParseFailure(id: requestID, commandName: "settings_set", error: "missing_arg:value"))
            }
            return request(.settingsSet, args: ["key": key, "value": value])
        default:
            return .failure(DebugControlParseFailure(id: requestID, commandName: nil, error: "unknown_command"))
        }
    }

    private static func actionFor(
        _ name: DebugControlCommandName,
        args: [String: Any]
    ) -> Result<DebugControlAction, DebugControlParseFailure> {
        func reject(_ error: String) -> Result<DebugControlAction, DebugControlParseFailure> {
            .failure(DebugControlParseFailure(id: nil, commandName: nil, error: error))
        }

        let allowedKeys: Set<String>
        switch name {
        case .stopDictation:
            allowedKeys = ["paste"]
        case .importAudio:
            allowedKeys = ["path"]
        case .openScreen:
            allowedKeys = ["screen"]
        case .settingsGet:
            allowedKeys = ["key"]
        case .settingsSet:
            allowedKeys = ["key", "value"]
        case .ping, .state, .status, .startDictation, .startMeeting, .stopMeeting, .pasteTargetOpen:
            allowedKeys = []
        }
        if let unknownKey = args.keys.sorted().first(where: { !allowedKeys.contains($0) }) {
            return reject(isEchoableWord(unknownKey) ? "unknown_arg:\(unknownKey)" : "unknown_arg")
        }

        switch name {
        case .ping:
            return .success(.ping)
        case .state, .status:
            return .success(.state)
        case .startDictation:
            return .success(.startDictation)
        case .stopDictation:
            var paste = false
            if let rawPaste = args["paste"] {
                if let value = jsonBool(rawPaste) {
                    paste = value
                } else if let text = rawPaste as? String, let value = DebugControlSettingsPolicy.parseBool(text) {
                    paste = value
                } else {
                    return reject("invalid_arg:paste")
                }
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
        case .pasteTargetOpen:
            return .success(.pasteTargetOpen)
        case .openScreen:
            guard let rawScreen = args["screen"] as? String else { return reject("missing_arg:screen") }
            guard DebugControlScreenPolicy.isAllowed(rawScreen) else { return reject("invalid_arg:screen") }
            return .success(.openScreen(screen: rawScreen))
        case .settingsGet:
            guard let key = args["key"] as? String else { return reject("missing_arg:key") }
            guard DebugControlSettingsPolicy.isAllowedKey(key) else { return reject("unknown_setting") }
            return .success(.settingsGet(key: key))
        case .settingsSet:
            guard let key = args["key"] as? String else { return reject("missing_arg:key") }
            guard DebugControlSettingsPolicy.isAllowedKey(key) else { return reject("unknown_setting") }
            guard let rawValue = args["value"] else { return reject("missing_arg:value") }
            let parsed: Bool?
            if let value = jsonBool(rawValue) {
                parsed = value
            } else if let text = rawValue as? String {
                parsed = DebugControlSettingsPolicy.parseBool(text)
            } else {
                parsed = nil
            }
            guard let value = parsed else { return reject("invalid_arg:value") }
            return .success(.settingsSet(key: key, value: value))
        }
    }
}

struct DebugControlResponse {
    let id: String?
    let command: String?
    let outcome: DebugControlOutcome
    let at: String
    let extraResult: [String: Any]

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "schema_version": DebugControlSchema.version,
            "ok": outcome.ok,
            "at": at,
        ]
        object["id"] = id.map { $0 as Any } ?? NSNull()
        object["command"] = command.map { $0 as Any } ?? NSNull()
        if let error = outcome.error {
            object["error"] = error
        }
        var result: [String: Any] = extraResult
        for (key, value) in outcome.result {
            result[key] = value
        }
        if !result.isEmpty {
            object["result"] = result
        }
        return object
    }

    func jsonData() -> Data? {
        let object = jsonObject()
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func jsonLine() -> Data? {
        guard var data = jsonData() else { return nil }
        data.append(0x0A)
        return data
    }
}

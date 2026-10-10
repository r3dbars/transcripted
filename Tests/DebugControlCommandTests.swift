// Covers the pure half of the debug test control surface
// (DebugControlCommand.swift): every command through JSON, argv and the
// URL scheme; the AutomatedLaunchEnvironment gate; settings and screen
// allowlists; session start/stop; and the versioned state JSON. The
// runtime half (DebugControlChannel.swift) is compiled only into debug
// builds (`build.sh`) and is driven on a Mac with
// scripts/dev/transcripted-debug.py.

import Foundation

func testDebugControlCommand() {
    runSuite("DebugControl parses every accepted JSON command") {
        assertEqual(debugParse(#"{"id":"a1","command":"ping"}"#), .success(DebugControlRequest(id: "a1", commandName: "ping", action: .ping)))
        assertEqual(debugParse(#"{"id":"a2","command":"state"}"#), .success(DebugControlRequest(id: "a2", commandName: "state", action: .state)))
        assertEqual(debugParse(#"{"id":"a2b","command":"status"}"#), .success(DebugControlRequest(id: "a2b", commandName: "state", action: .state)), "status is an alias of state")
        assertEqual(debugParse(#"{"id":"a3","command":"start_dictation"}"#), .success(DebugControlRequest(id: "a3", commandName: "start_dictation", action: .startDictation)))
        assertEqual(debugParse(#"{"id":"a4","command":"stop_dictation"}"#), .success(DebugControlRequest(id: "a4", commandName: "stop_dictation", action: .stopDictation(paste: false))), "paste defaults to false")
        assertEqual(debugParse(#"{"id":"a5","command":"stop_dictation","args":{"paste":true}}"#), .success(DebugControlRequest(id: "a5", commandName: "stop_dictation", action: .stopDictation(paste: true))))
        assertEqual(debugParse(#"{"id":"a6","command":"start_meeting"}"#), .success(DebugControlRequest(id: "a6", commandName: "start_meeting", action: .startMeeting)))
        assertEqual(debugParse(#"{"id":"a7","command":"stop_meeting"}"#), .success(DebugControlRequest(id: "a7", commandName: "stop_meeting", action: .stopMeeting)))
        assertEqual(debugParse(#"{"id":"a8","command":"import_audio","args":{"path":"/tmp/x.wav"}}"#), .success(DebugControlRequest(id: "a8", commandName: "import_audio", action: .importAudio(path: "/tmp/x.wav"))))
        assertEqual(debugParse(#"{"id":"a9","command":"paste_target_open"}"#), .success(DebugControlRequest(id: "a9", commandName: "paste_target_open", action: .pasteTargetOpen)))
        assertEqual(debugParse(#"{"id":"a10","command":"open_screen","args":{"screen":"today"}}"#), .success(DebugControlRequest(id: "a10", commandName: "open_screen", action: .openScreen(screen: "today"))))
        assertEqual(debugParse(#"{"id":"a11","command":"settings_get","args":{"key":"show_in_dock"}}"#), .success(DebugControlRequest(id: "a11", commandName: "settings_get", action: .settingsGet(key: "show_in_dock"))))
        assertEqual(debugParse(#"{"id":"a12","command":"settings_set","args":{"key":"show_in_dock","value":false}}"#), .success(DebugControlRequest(id: "a12", commandName: "settings_set", action: .settingsSet(key: "show_in_dock", value: false))))
        assertEqual(DebugControlCommandName.allCases.count, 12, "adding a command means adding a parse case, an argv case, a URL case, and a doc row")
    }

    runSuite("DebugControl parses the CLI argv form for every command") {
        assertEqual(debugArgv(["state"]), .success(DebugControlRequest(id: "cli", commandName: "state", action: .state)))
        assertEqual(debugArgv(["ping"]), .success(DebugControlRequest(id: "cli", commandName: "ping", action: .ping)))
        assertEqual(debugArgv(["dictation", "start"]), .success(DebugControlRequest(id: "cli", commandName: "start_dictation", action: .startDictation)))
        assertEqual(debugArgv(["dictation", "stop"]), .success(DebugControlRequest(id: "cli", commandName: "stop_dictation", action: .stopDictation(paste: false))))
        assertEqual(debugArgv(["dictation", "stop", "--paste"]), .success(DebugControlRequest(id: "cli", commandName: "stop_dictation", action: .stopDictation(paste: true))))
        assertEqual(debugArgv(["meeting", "start"]), .success(DebugControlRequest(id: "cli", commandName: "start_meeting", action: .startMeeting)))
        assertEqual(debugArgv(["meeting", "stop"]), .success(DebugControlRequest(id: "cli", commandName: "stop_meeting", action: .stopMeeting)))
        assertEqual(debugArgv(["import", "/tmp/x.wav"]), .success(DebugControlRequest(id: "cli", commandName: "import_audio", action: .importAudio(path: "/tmp/x.wav"))))
        assertEqual(debugArgv(["paste-target", "open"]), .success(DebugControlRequest(id: "cli", commandName: "paste_target_open", action: .pasteTargetOpen)))
        assertEqual(debugArgv(["open", "people"]), .success(DebugControlRequest(id: "cli", commandName: "open_screen", action: .openScreen(screen: "people"))))
        assertEqual(debugArgv(["settings", "get", "usage_stats"]), .success(DebugControlRequest(id: "cli", commandName: "settings_get", action: .settingsGet(key: "usage_stats"))))
        assertEqual(debugArgv(["settings", "set", "crash_reports", "false"]), .success(DebugControlRequest(id: "cli", commandName: "settings_set", action: .settingsSet(key: "crash_reports", value: false))))
    }

    runSuite("DebugControl parses the URL scheme for every command") {
        assertEqual(debugURL("transcripted-debug://state"), .success(DebugControlRequest(id: "url", commandName: "state", action: .state)))
        assertEqual(debugURL("transcripted-debug://dictation/start"), .success(DebugControlRequest(id: "url", commandName: "start_dictation", action: .startDictation)))
        assertEqual(debugURL("transcripted-debug://dictation/stop?paste=true"), .success(DebugControlRequest(id: "url", commandName: "stop_dictation", action: .stopDictation(paste: true))))
        assertEqual(debugURL("transcripted-debug://meeting/start"), .success(DebugControlRequest(id: "url", commandName: "start_meeting", action: .startMeeting)))
        assertEqual(debugURL("transcripted-debug://meeting/stop"), .success(DebugControlRequest(id: "url", commandName: "stop_meeting", action: .stopMeeting)))
        assertEqual(debugURL("transcripted-debug://import?path=/tmp/x.wav"), .success(DebugControlRequest(id: "url", commandName: "import_audio", action: .importAudio(path: "/tmp/x.wav"))))
        assertEqual(debugURL("transcripted-debug://paste-target/open"), .success(DebugControlRequest(id: "url", commandName: "paste_target_open", action: .pasteTargetOpen)))
        assertEqual(debugURL("transcripted-debug://open?screen=menubar"), .success(DebugControlRequest(id: "url", commandName: "open_screen", action: .openScreen(screen: "menubar"))))
        assertEqual(debugURL("transcripted-debug://settings/get?key=show_in_dock"), .success(DebugControlRequest(id: "url", commandName: "settings_get", action: .settingsGet(key: "show_in_dock"))))
        assertEqual(debugURL("transcripted-debug://settings/set?key=show_in_dock&value=true"), .success(DebugControlRequest(id: "url", commandName: "settings_set", action: .settingsSet(key: "show_in_dock", value: true))))
        assertEqual(debugURL("https://example.com/state").error, "unknown_scheme")
    }

    runSuite("DebugControl rejects bad payloads without losing a usable id") {
        assertEqual(debugParseError(#"{"id":"b1","command":"launch_rockets"}"#), DebugControlParseFailure(id: "b1", commandName: "launch_rockets", error: "unknown_command"))
        assertEqual(debugParseError("{not json"), DebugControlParseFailure(id: nil, commandName: nil, error: "malformed_json"))
        assertEqual(debugParseError(#"{"command":"ping"}"#), DebugControlParseFailure(id: nil, commandName: "ping", error: "missing_id"))
        assertEqual(debugParseError(#"{"id":"b2","command":"import_audio"}"#)?.error, "missing_arg:path")
        assertEqual(debugParseError(#"{"id":"b3","command":"import_audio","args":{"path":"relative.wav"}}"#)?.error, "invalid_arg:path")
        assertEqual(debugParseError(#"{"id":"b4","command":"open_screen","args":{"screen":"bank"}}"#)?.error, "invalid_arg:screen")
        assertEqual(debugParseError(#"{"id":"b5","command":"settings_get","args":{"key":"transcriptSaveLocation"}}"#)?.error, "unknown_setting")
        assertEqual(debugParseError(#"{"id":"b6","command":"settings_set","args":{"key":"show_in_dock","value":"maybe"}}"#)?.error, "invalid_arg:value")
        assertEqual(debugParseError(#"{"id":"b7","command":"ping","args":{"fast":true}}"#)?.error, "unknown_arg:fast")
        assertEqual(debugArgv(["dictation", "hold"]).error, "unknown_command")
        assertEqual(debugArgv(["import"]).error, "missing_arg:path")
        assertEqual(debugArgv(["open", "bank"]).error, "invalid_arg:screen")
    }

    runSuite("DebugControl refuses to start unless the harness is active and the control dir is absolute") {
        assertEqual(DebugControlAdmission.refusal(harnessActive: false, controlDirectory: "/tmp/ctrl"), "harness_inactive")
        assertEqual(DebugControlAdmission.refusal(harnessActive: true, controlDirectory: nil), "control_dir_required")
        assertEqual(DebugControlAdmission.refusal(harnessActive: true, controlDirectory: "relative"), "control_dir_required")
        assertEqual(DebugControlAdmission.refusal(harnessActive: true, controlDirectory: ""), "control_dir_required")
        assertNil(DebugControlAdmission.refusal(harnessActive: true, controlDirectory: "/tmp/ctrl"))
        assertTrue(
            AutomatedLaunchEnvironment.isActive(environment: ["TRANSCRIPTED_AUTOMATED_HARNESS": "1"]),
            "the harness key the debug CLI sets must activate AutomatedLaunchEnvironment"
        )
        assertFalse(
            AutomatedLaunchEnvironment.isActive(environment: [:]),
            "a normal launch is not a harness launch"
        )
    }

    runSuite("DebugControl session policy starts and stops dictation and meetings") {
        var snapshot = DebugControlSessionSnapshot.idle()
        assertEqual(DebugControlSessionPolicy.apply(.startDictation, to: snapshot).okSnapshot()?.dictationActive, true)
        snapshot.dictationActive = true
        assertEqual(DebugControlSessionPolicy.apply(.startDictation, to: snapshot).failureCode(), "dictation_already_active")
        assertEqual(DebugControlSessionPolicy.apply(.stopDictation(paste: false), to: snapshot).okSnapshot()?.dictationActive, false)
        snapshot.dictationActive = false
        assertEqual(DebugControlSessionPolicy.apply(.stopDictation(paste: false), to: snapshot).failureCode(), "dictation_not_active")

        assertEqual(DebugControlSessionPolicy.apply(.startMeeting, to: snapshot).okSnapshot()?.meetingState, "recording")
        snapshot.meetingState = "recording"
        assertEqual(DebugControlSessionPolicy.apply(.startMeeting, to: snapshot).failureCode(), "meeting_capture_active")
        assertEqual(DebugControlSessionPolicy.apply(.importAudio(path: "/tmp/x.wav"), to: snapshot).failureCode(), "meeting_capture_active")
        assertEqual(DebugControlSessionPolicy.apply(.stopMeeting, to: snapshot).okSnapshot()?.meetingState, "transcribing")
        snapshot.meetingState = "ready"
        assertEqual(DebugControlSessionPolicy.apply(.stopMeeting, to: snapshot).failureCode(), "meeting_not_recording")
        assertNil(DebugControlSessionPolicy.apply(.importAudio(path: "/tmp/x.wav"), to: snapshot).failureCode())
    }

    runSuite("DebugControl settings and screens stay on the allowlist") {
        var snapshot = DebugControlSessionSnapshot.idle()
        assertEqual(snapshot.settings["show_in_dock"], true)
        snapshot = DebugControlSessionPolicy.apply(.settingsSet(key: "show_in_dock", value: false), to: snapshot).okSnapshot() ?? snapshot
        assertEqual(snapshot.settings["show_in_dock"], false)
        assertEqual(DebugControlSessionPolicy.apply(.settingsSet(key: "transcriptSaveLocation", value: true), to: snapshot).failureCode(), "unknown_setting")
        snapshot = DebugControlSessionPolicy.apply(.openScreen(screen: "connect_agent"), to: snapshot).okSnapshot() ?? snapshot
        assertEqual(snapshot.openScreen, "connect_agent")
        snapshot = DebugControlSessionPolicy.apply(.pasteTargetOpen, to: snapshot).okSnapshot() ?? snapshot
        assertTrue(snapshot.pasteTargetOpen, "paste-target open should mark the debug field as shown")
        assertEqual(DebugControlSettingsPolicy.keys.count, 8, "every allowlisted setting needs a live mapping in the channel")
        for key in DebugControlSettingsPolicy.keys {
            assertTrue(
                DebugControlSettingsPolicy.persistKey(key) != nil,
                "settings_set must know the UserDefaults key for \(key)"
            )
        }
        assertEqual(
            Set(DebugControlSettingsPolicy.persistKeys.keys),
            Set(DebugControlSettingsPolicy.keys),
            "persist key map must cover the allowlist and nothing else"
        )
        let merged = DebugControlSettingsPolicy.applying(
            false,
            persistKey: "observability-crash-reporting-enabled",
            intoArgumentDomain: [
                "observability-anonymous-analytics-enabled": "NO",
                "observability-crash-reporting-enabled": "NO",
            ]
        )
        assertEqual(merged["observability-crash-reporting-enabled"] as? Bool, false)
        assertEqual(
            merged["observability-anonymous-analytics-enabled"] as? String,
            "NO",
            "settings_set must keep other argument-domain launch overrides"
        )
        assertTrue(DebugControlScreenPolicy.ids.contains("menubar"))
        assertTrue(DebugControlScreenPolicy.ids.contains("onboarding"))
    }

    runSuite("DebugControl state JSON carries a schema version and no user content keys") {
        let encoded = DebugControlStateCodec.encode(.idle(), pid: 42)
        for key in DebugControlStateCodec.requiredStateKeys() {
            assertTrue(encoded[key] != nil, "state JSON must include \(key)")
        }
        assertEqual(encoded["schema_version"] as? Int, DebugControlSchema.version)
        assertEqual(encoded["pid"] as? Int, 42)
        assertEqual(encoded["dictation_active"] as? Bool, false)
        assertEqual(encoded["meeting_state"] as? String, "ready")
        assertEqual((encoded["automation_ids"] as? [String: String])?["start_dictation"], MenuBarAutomationID.startDictation.rawValue)
        assertEqual((encoded["automation_ids"] as? [String: String])?["start_meeting"], MenuBarAutomationID.startMeeting.rawValue)
        assertEqual((encoded["automation_ids"] as? [String: String])?["status_item"], MenuBarAutomationID.statusItemButton.rawValue)
        let forbidden = ["title", "text", "path", "speaker", "email", "token"]
        for key in encoded.keys {
            for fragment in forbidden {
                assertFalse(key.contains(fragment), "state keys must not carry \(fragment): \(key)")
            }
        }

        let line = DebugControlResponse(
            id: "c1",
            command: "state",
            outcome: .success(),
            at: "2026-10-10T12:00:00.000Z",
            extraResult: encoded
        ).jsonLine()
        assertNotNil(line)
        if let line {
            assertEqual(line.last, 0x0A)
            let decoded = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            assertEqual(decoded?["schema_version"] as? Int, 1)
            assertEqual(decoded?["ok"] as? Bool, true)
            assertEqual((decoded?["result"] as? [String: Any])?["meeting_state"] as? String, "ready")
        }
    }
}

private func debugParse(_ json: String) -> Result<DebugControlRequest, DebugControlParseFailure> {
    DebugControlCommandParser.parse(Data(json.utf8))
}

private func debugParseError(_ json: String) -> DebugControlParseFailure? {
    if case .failure(let failure) = debugParse(json) { return failure }
    return nil
}

private func debugArgv(_ argv: [String]) -> Result<DebugControlRequest, DebugControlParseFailure> {
    DebugControlCommandParser.parseArgv(argv)
}

private func debugURL(_ raw: String) -> Result<DebugControlRequest, DebugControlParseFailure> {
    DebugControlCommandParser.parseURLString(raw)
}

private extension Result where Success == DebugControlSessionSnapshot, Failure == String {
    func okSnapshot() -> DebugControlSessionSnapshot? {
        if case .success(let snapshot) = self { return snapshot }
        return nil
    }

    func failureCode() -> String? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

private extension Result where Success == DebugControlRequest, Failure == DebugControlParseFailure {
    var error: String? {
        if case .failure(let failure) = self { return failure.error }
        return nil
    }
}

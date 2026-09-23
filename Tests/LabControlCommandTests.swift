// LabControlCommandTests.swift
// Covers the pure half of the lab control channel (LabControlCommand.swift):
// command parsing/validation, the env-var gate, inbox file-name filtering,
// meeting-state gates, and the response line encoding. The runtime half
// (LabControlChannel.swift) needs a live app delegate and is exercised on a
// Mac with scripts/hillclimb/lab_control.py (docs/lab-control-channel.md).

import Foundation

func testLabControlCommand() {
    runSuite("LabControl parses every accepted command") {
        assertEqual(labParse(#"{"id":"a1","command":"ping"}"#), .success(LabControlRequest(id: "a1", commandName: "ping", action: .ping)))
        assertEqual(labParse(#"{"id":"a2","command":"status","args":null}"#), .success(LabControlRequest(id: "a2", commandName: "status", action: .status)))
        assertEqual(labParse(#"{"id":"a3","command":"start_dictation","args":{}}"#), .success(LabControlRequest(id: "a3", commandName: "start_dictation", action: .startDictation)))
        assertEqual(labParse(#"{"id":"a4","command":"stop_dictation"}"#), .success(LabControlRequest(id: "a4", commandName: "stop_dictation", action: .stopDictation(paste: true))), "paste defaults to true like the menu path")
        assertEqual(labParse(#"{"id":"a5","command":"stop_dictation","args":{"paste":false}}"#), .success(LabControlRequest(id: "a5", commandName: "stop_dictation", action: .stopDictation(paste: false))))
        assertEqual(labParse(#"{"id":"a6","command":"start_meeting"}"#), .success(LabControlRequest(id: "a6", commandName: "start_meeting", action: .startMeeting)))
        assertEqual(labParse(#"{"id":"a7","command":"stop_meeting"}"#), .success(LabControlRequest(id: "a7", commandName: "stop_meeting", action: .stopMeeting)))
        assertEqual(labParse(#"{"id":"a8","command":"import_audio","args":{"path":"/tmp/x.wav"}}"#), .success(LabControlRequest(id: "a8", commandName: "import_audio", action: .importAudio(path: "/tmp/x.wav"))))
        assertEqual(LabControlCommandName.allCases.count, 7, "adding a command means adding a parse case and a doc row")
    }

    runSuite("LabControl rejects bad files without losing the id") {
        assertEqual(labParseError(#"{"id":"b1","command":"launch_rockets"}"#), LabControlParseFailure(id: "b1", commandName: "launch_rockets", error: "unknown_command"))
        assertEqual(labParseError("{not json"), LabControlParseFailure(id: nil, commandName: nil, error: "malformed_json"))
        assertEqual(labParseError("[1,2]"), LabControlParseFailure(id: nil, commandName: nil, error: "not_an_object"))
        assertEqual(labParseError(#"{"command":"ping"}"#), LabControlParseFailure(id: nil, commandName: "ping", error: "missing_id"))
        assertEqual(labParseError(#"{"id":"has space","command":"ping"}"#), LabControlParseFailure(id: nil, commandName: "ping", error: "invalid_id"))
        assertEqual(labParseError(#"{"id":7,"command":"ping"}"#)?.error, "invalid_id")
        assertEqual(labParseError(#"{"id":"b2"}"#), LabControlParseFailure(id: "b2", commandName: nil, error: "missing_command"))
        assertEqual(labParseError(#"{"id":"b3","command":3}"#)?.error, "invalid_command")
        assertEqual(labParseError(#"{"id":"b4","command":"Ping Now!"}"#), LabControlParseFailure(id: "b4", commandName: nil, error: "unknown_command"), "odd command text is not echoed")
        assertEqual(labParseError(#"{"id":"b5","command":"ping","args":[1]}"#)?.error, "invalid_args")
        assertEqual(labParseError(#"{"id":"b6","command":"ping","args":{"fast":true}}"#)?.error, "unknown_arg:fast")
        assertEqual(labParseError(#"{"id":"b7","command":"stop_dictation","args":{"paste":1}}"#)?.error, "invalid_arg:paste", "only JSON booleans count")
        assertEqual(labParseError(#"{"id":"b8","command":"import_audio"}"#)?.error, "missing_arg:path")
        assertEqual(labParseError(#"{"id":"b9","command":"import_audio","args":{"path":"relative.wav"}}"#)?.error, "invalid_arg:path")
        assertEqual(labParseError(#"{"id":"b10","command":"import_audio","args":{"path":5}}"#)?.error, "invalid_arg:path")

        let oversized = Data(repeating: 0x20, count: LabControlCommandParser.maxCommandBytes + 1)
        if case .failure(let failure) = LabControlCommandParser.parse(oversized) {
            assertEqual(failure.error, "payload_too_large")
        } else {
            assertTrue(false, "oversized payload must be rejected")
        }
        assertEqual(labParseError(#"{"id":"\#(String(repeating: "x", count: 129))","command":"ping"}"#)?.error, "invalid_id")
    }

    runSuite("LabControl is off unless the env var is an absolute path") {
        assertNil(LabControlCommandParser.controlDirectoryURL(fromEnvironmentValue: nil))
        assertNil(LabControlCommandParser.controlDirectoryURL(fromEnvironmentValue: ""))
        assertNil(LabControlCommandParser.controlDirectoryURL(fromEnvironmentValue: "   "))
        assertNil(LabControlCommandParser.controlDirectoryURL(fromEnvironmentValue: "relative/lab"))
        assertEqual(LabControlCommandParser.controlDirectoryURL(fromEnvironmentValue: " /tmp/lab/ ")?.path, "/tmp/lab")
    }

    runSuite("LabControl only reads finished .json inbox files") {
        assertTrue(LabControlCommandParser.isInboxCommandFileName("0001-a1.json"))
        assertFalse(LabControlCommandParser.isInboxCommandFileName("0001-a1.json.tmp"))
        assertFalse(LabControlCommandParser.isInboxCommandFileName(".0001-a1.json"))
        assertFalse(LabControlCommandParser.isInboxCommandFileName(".json"))
        assertFalse(LabControlCommandParser.isInboxCommandFileName("notes.txt"))
        assertEqual(LabControlCommandParser.echoableFileName("0001-a1.json"), "0001-a1.json")
        assertNil(LabControlCommandParser.echoableFileName("my file.json"))
    }

    runSuite("LabControl meeting gates mirror the menu-bar toggle") {
        assertEqual(LabControlMeetingPolicy.startRejection(.ready), nil)
        assertEqual(LabControlMeetingPolicy.startRejection(.transcribing), nil)
        assertEqual(LabControlMeetingPolicy.startRejection(.error("boom")), nil)
        assertEqual(LabControlMeetingPolicy.startRejection(.recording), "meeting_capture_active")
        assertEqual(LabControlMeetingPolicy.startRejection(.startingRecording), "meeting_capture_active")
        assertEqual(LabControlMeetingPolicy.importRejection(.stoppingRecording), "meeting_capture_active")
        assertEqual(LabControlMeetingPolicy.stopPlan(.recording), .stop)
        assertEqual(LabControlMeetingPolicy.stopPlan(.startingRecording), .joinPendingStartThenStop)
        assertNil(LabControlMeetingPolicy.stopPlan(.stoppingRecording))
        assertNil(LabControlMeetingPolicy.stopPlan(.idle))
        assertEqual(LabControlMeetingPolicy.stateName(.error("private detail")), "error", "state names never carry error text")
        assertEqual(LabControlMeetingPolicy.stateName(.startingRecording), "starting_recording")
    }

    runSuite("LabControl response lines are single JSON lines") {
        let okResult: [String: Any] = ["pid": 42, "meeting_state": "ready", "dictation_active": false]
        let okLine = LabControlResponse(
            id: "c1",
            command: "status",
            file: "0001-c1.json",
            outcome: LabControlOutcome.success(okResult),
            at: "2026-09-23T10:00:00.123Z",
            receivedMonotonicMs: 1000,
            monotonicMs: 1003
        ).jsonLine()
        assertNotNil(okLine)
        if let okLine {
            assertEqual(okLine.last, 0x0A, "each response ends with a newline")
            assertEqual(okLine.filter { $0 == 0x0A }.count, 1, "exactly one line per response")
            let decoded = (try? JSONSerialization.jsonObject(with: okLine)) as? [String: Any]
            assertEqual(decoded?["id"] as? String, "c1")
            assertEqual(decoded?["ok"] as? Bool, true)
            assertEqual(decoded?["monotonic_ms"] as? Int, 1003)
            assertEqual(decoded?["received_monotonic_ms"] as? Int, 1000)
            assertNil(decoded?["error"], "a success carries no error key")
            assertEqual((decoded?["result"] as? [String: Any])?["meeting_state"] as? String, "ready")
        }

        let failLine = LabControlResponse(
            id: nil,
            command: nil,
            file: nil,
            outcome: LabControlOutcome.failure("malformed_json"),
            at: "2026-09-23T10:00:00.123Z",
            receivedMonotonicMs: 5,
            monotonicMs: 6
        ).jsonLine()
        let failed = failLine.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        assertTrue(failed?["id"] is NSNull, "unknown id is written as null")
        assertEqual(failed?["ok"] as? Bool, false)
        assertEqual(failed?["error"] as? String, "malformed_json")
        assertNil(failed?["result"])

        assertEqual(LabControlClock.monotonicMilliseconds(uptime: 2.5), 2500)
    }
}

private func labParse(_ json: String) -> Result<LabControlRequest, LabControlParseFailure> {
    LabControlCommandParser.parse(Data(json.utf8))
}

private func labParseError(_ json: String) -> LabControlParseFailure? {
    if case .failure(let failure) = labParse(json) {
        return failure
    }
    return nil
}

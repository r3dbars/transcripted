import Foundation

func testMeetingStateDiagnosticName() {
    runSuite("Meeting diagnostics and control JSON preserve their existing state names") {
        let cases: [(MeetingSessionState, String, String)] = [
            (.idle, "idle", "idle"),
            (.loadingModels, "loading_models", "loadingModels"),
            (.ready, "ready", "ready"),
            (.startingRecording, "starting_recording", "startingRecording"),
            (.recording, "recording", "recording"),
            (.stoppingRecording, "stopping_recording", "stoppingRecording"),
            (.transcribing, "transcribing", "transcribing"),
            (.error("synthetic detail"), "error", "error"),
        ]
        for (state, diagnostic, legacyEvent) in cases {
            assertEqual(state.diagnosticName, diagnostic)
            assertEqual(LabControlMeetingPolicy.stateName(state), diagnostic)
            assertEqual(state.legacyEventName, legacyEvent)
            let line = LabControlResponse(
                id: "synthetic-state", command: "status", file: nil,
                outcome: .success(["meeting_state": LabControlMeetingPolicy.stateName(state)]),
                at: "2026-01-01T00:00:00Z", receivedMonotonicMs: 0, monotonicMs: 0
            ).jsonLine()
            let object = line.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let result = object?["result"] as? [String: Any]
            assertEqual(result?["meeting_state"] as? String, diagnostic)
        }
        assertEqual(MeetingSessionState.error("another synthetic detail").diagnosticName, "error")
        assertEqual(MeetingSessionState.error("another synthetic detail").legacyEventName, "error")
    }
}

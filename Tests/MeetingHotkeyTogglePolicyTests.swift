import Foundation

func testMeetingHotkeyTogglePolicy() {
    runSuite("the meeting hotkey starts when the session is idle") {
        assertEqual(
            MeetingHotkeyTogglePolicy.action(for: .idle, startCallInFlight: false),
            .start
        )
        assertEqual(
            MeetingHotkeyTogglePolicy.action(for: .ready, startCallInFlight: false),
            .start
        )
    }

    runSuite("the meeting hotkey stops only a steady recording") {
        assertEqual(
            MeetingHotkeyTogglePolicy.action(for: .recording, startCallInFlight: false),
            .stop
        )
    }

    runSuite("the meeting hotkey does not stop an auto-start that is still loading") {
        for state: MeetingSessionState in [.loadingModels, .startingRecording, .stoppingRecording] {
            assertEqual(
                MeetingHotkeyTogglePolicy.action(for: state, startCallInFlight: false),
                .ignore,
                "\(state) must not toggle"
            )
        }
        assertEqual(
            MeetingHotkeyTogglePolicy.action(for: .ready, startCallInFlight: true),
            .ignore,
            "a start already in flight (auto-start loading) must not be stopped or doubled"
        )
        assertEqual(
            MeetingHotkeyTogglePolicy.action(for: .idle, startCallInFlight: true),
            .ignore,
            "hotkey during an in-flight auto-start must not start a second recording"
        )
    }
}

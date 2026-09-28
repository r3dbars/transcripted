func testMenuBarMeetingCapturePhase() {
    runSuite("MenuBarMeetingCapturePhase — only live capture states have a phase") {
        assertEqual(MenuBarMeetingCapturePhase.resolve(.startingRecording), .starting, "mic engaging should read as starting")
        assertEqual(MenuBarMeetingCapturePhase.resolve(.recording), .recording, "steady capture should read as recording")
        assertEqual(MenuBarMeetingCapturePhase.resolve(.stoppingRecording), .saving, "capture teardown should read as saving")
        assertEqual(MenuBarMeetingCapturePhase.resolve(.idle), nil, "idle has no capture phase")
        assertEqual(MenuBarMeetingCapturePhase.resolve(.loadingModels), nil, "loading models has no capture phase")
        assertEqual(MenuBarMeetingCapturePhase.resolve(.ready), nil, "ready has no capture phase")
        assertEqual(MenuBarMeetingCapturePhase.resolve(.transcribing), nil, "transcribing after stop is not a live capture")
        assertEqual(MenuBarMeetingCapturePhase.resolve(.error("boom")), nil, "an error is not a live capture")
    }

    runSuite("MenuBarMeetingCapturePhase — header and right-click copy") {
        assertEqual(MenuBarMeetingCapturePhase.starting.headerText, "Starting…", "starting should not claim to be recording yet")
        assertEqual(MenuBarMeetingCapturePhase.recording.headerText, "Recording", "steady capture keeps the Recording label")
        assertEqual(MenuBarMeetingCapturePhase.saving.headerText, "Saving…", "saving should not claim to still be recording")

        assertEqual(MenuBarMeetingCapturePhase.starting.quickMenuTitle, "Stop Meeting", "a starting meeting can still be stopped")
        assertEqual(MenuBarMeetingCapturePhase.recording.quickMenuTitle, "Stop Meeting", "a recording meeting can be stopped")
        assertEqual(MenuBarMeetingCapturePhase.saving.quickMenuTitle, "Saving Meeting…", "a saving meeting has nothing left to stop")

        assertTrue(MenuBarMeetingCapturePhase.starting.allowsStop, "stop joins a pending start")
        assertTrue(MenuBarMeetingCapturePhase.recording.allowsStop, "stop works while recording")
        assertFalse(MenuBarMeetingCapturePhase.saving.allowsStop, "the saving item should be disabled")
    }
}

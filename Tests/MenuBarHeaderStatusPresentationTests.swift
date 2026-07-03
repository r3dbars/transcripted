func testMenuBarHeaderStatusPresentation() {
    runSuite("MenuBarHeaderStatusPresentation — recording wins over every other state") {
        let recordingWhileReady = MenuBarHeaderStatusPresentation.resolve(
            isReady: true,
            isMeetingRecording: true,
            warmupSubtitle: "Warming up"
        )
        assertEqual(recordingWhileReady.text, "Recording", "recording should replace the Ready label")
        assertEqual(recordingWhileReady.tone, .recording, "recording should use the recording tone")

        let recordingWhileWarming = MenuBarHeaderStatusPresentation.resolve(
            isReady: false,
            isMeetingRecording: true,
            warmupSubtitle: "Loading meeting tools"
        )
        assertEqual(
            recordingWhileWarming.text,
            "Recording",
            "an active capture should outrank warmup copy — the user must never misread recording state"
        )
        assertEqual(recordingWhileWarming.tone, .recording, "recording tone should win during warmup too")
    }

    runSuite("MenuBarHeaderStatusPresentation — idle states keep the existing copy") {
        let ready = MenuBarHeaderStatusPresentation.resolve(
            isReady: true,
            isMeetingRecording: false,
            warmupSubtitle: "ignored"
        )
        assertEqual(ready.text, "Ready", "idle ready header should keep its Ready label")
        assertEqual(ready.tone, .ready, "idle ready header should keep the ready tone")

        let warming = MenuBarHeaderStatusPresentation.resolve(
            isReady: false,
            isMeetingRecording: false,
            warmupSubtitle: "Downloading model"
        )
        assertEqual(warming.text, "Downloading model", "warmup header should surface the warmup subtitle as-is")
        assertEqual(warming.tone, .working, "warmup header should use the working tone")
    }
}

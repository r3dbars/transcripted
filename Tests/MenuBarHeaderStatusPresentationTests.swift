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

    runSuite("MenuBarHeaderStatusPresentation — a meeting still transcribing is not Ready") {
        let transcribing = MenuBarHeaderStatusPresentation.resolve(
            isReady: true,
            isMeetingRecording: false,
            warmupSubtitle: "ignored",
            transcribingStatus: "Transcribing 42%"
        )
        assertEqual(transcribing.text, "Transcribing 42%", "the header should say a transcript is still being made")
        assertEqual(transcribing.tone, .working, "transcribing should use the working tone")

        let recordingWhileTranscribing = MenuBarHeaderStatusPresentation.resolve(
            isReady: true,
            isMeetingRecording: true,
            warmupSubtitle: "ignored",
            transcribingStatus: "Transcribing 42%"
        )
        assertEqual(recordingWhileTranscribing.text, "Recording", "a live recording still wins over an earlier transcript")

        let emptyStatus = MenuBarHeaderStatusPresentation.resolve(
            isReady: true,
            isMeetingRecording: false,
            warmupSubtitle: "ignored",
            transcribingStatus: ""
        )
        assertEqual(emptyStatus.text, "Ready", "an empty transcribing status should fall back to Ready")
    }

    runSuite("MenuBarHeaderStatusPresentation — starting and saving are not red Recording") {
        let starting = MenuBarHeaderStatusPresentation.resolve(
            isReady: true,
            isMeetingRecording: true,
            warmupSubtitle: "ignored",
            capturePhase: .starting
        )
        assertEqual(starting.text, "Starting…", "the header should say the meeting is starting while the mic engages")
        assertEqual(starting.tone, .working, "starting should use the working tone, not recording red")

        let saving = MenuBarHeaderStatusPresentation.resolve(
            isReady: true,
            isMeetingRecording: true,
            warmupSubtitle: "ignored",
            transcribingStatus: "Transcribing 42%",
            capturePhase: .saving
        )
        assertEqual(saving.text, "Saving…", "the header should say the audio is being saved after Stop")
        assertEqual(saving.tone, .working, "saving should use the working tone, not recording red")

        let recording = MenuBarHeaderStatusPresentation.resolve(
            isReady: true,
            isMeetingRecording: true,
            warmupSubtitle: "ignored",
            capturePhase: .recording
        )
        assertEqual(recording.text, "Recording", "steady capture keeps the Recording label")
        assertEqual(recording.tone, .recording, "steady capture keeps the recording tone")
    }
}

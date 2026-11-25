// What setup's practice screens say while a real take happens: they wait for
// paste access and the voice model, name the take while it runs, and call it
// done only once it landed.

func testOnboardingPracticePresentation() {
    typealias P = OnboardingPracticePresentation

    func phase(
        accessibility: Bool = true,
        keyEnabled: Bool = true,
        model: ParakeetModelState = .ready,
        recording: Bool = false,
        transcribing: Bool = false,
        done: Bool = false,
        heardNothing: Bool = false
    ) -> P.Phase {
        P.phase(
            accessibilityGranted: accessibility,
            keyEnabled: keyEnabled,
            modelState: model,
            isRecording: recording,
            isTranscribing: transcribing,
            takeDone: done,
            heardNothing: heardNothing
        )
    }

    runSuite("Practice waits for paste access, the key and the voice model") {
        assertEqual(phase(accessibility: false), .needsPasteAccess, "the key can't work without paste access")
        assertEqual(phase(keyEnabled: false), .keyOff, "a turned-off key says so")
        assertEqual(phase(model: .downloading(progress: 0.42)), .downloading(progress: 0.42), "a downloading model shows its progress")
        assertEqual(phase(model: .downloading(progress: 0)), .downloading(progress: nil), "no progress yet shows a plain wait")
        assertEqual(phase(model: .loading), .loading, "a loading model is a wait")
        assertEqual(phase(model: .failed("x")), .failed, "a failed model points to Skip")
        assertEqual(phase(model: .notLoaded), .ready, "a model that loads on first use doesn't block a take")
        assertEqual(phase(model: .cached), .ready, "a downloaded model is ready to try")
    }

    runSuite("Practice follows a real take from start to landed") {
        assertEqual(phase(model: .downloading(progress: 0.5), recording: true), .listening, "a take that started is listening, even mid-download")
        assertEqual(phase(transcribing: true), .transcribing, "after the key comes up the words are being written")
        assertEqual(phase(heardNothing: true), .heardNothing, "an empty take asks for another try")
        assertEqual(phase(accessibility: false, done: true), .done, "a landed take stays done")

        let done = P.make(kind: .first, phase: .done, keyDisplay: "Right ⌥", keyBehavior: .holdOrTap)
        assertTrue(done.statusIsLive, "it worked is the one green moment")
        assertEqual(done.status, "That's it. It works the same in every app.", "the first take ends on the promise of every app")

        let listening = P.make(kind: .first, phase: .listening, keyDisplay: "Right ⌥", keyBehavior: .holdOrTap)
        assertTrue(listening.statusIsLive, "listening is live")
        let failed = P.make(kind: .first, phase: .failed, keyDisplay: "Right ⌥", keyBehavior: .holdOrTap)
        assertFalse(failed.statusIsLive, "a failure is not green")
        let downloading = P.make(kind: .first, phase: .downloading(progress: 0.42), keyDisplay: "Right ⌥", keyBehavior: .holdOrTap)
        assertEqual(downloading.status, "Getting the voice model ready · 42%", "the wait names the voice model")
        assertTrue(downloading.showsProgress, "the wait shows a bar")
    }

    runSuite("Practice teaches the key the way it's set") {
        let hold = P.make(kind: .first, phase: .ready, keyDisplay: "Right ⌥", keyBehavior: .holdOrTap)
        assertEqual(hold.instruction, "Hold Right ⌥ and say anything. Let go to paste.", "the first take is a hold")
        assertNil(hold.status, "a ready screen is just the instruction")
        let tap = P.make(kind: .first, phase: .ready, keyDisplay: "Fn", keyBehavior: .tapToToggle)
        assertEqual(tap.instruction, "Tap Fn, say anything, then tap it again.", "tap to toggle teaches a tap")
        let handsFree = P.make(kind: .handsFree, phase: .ready, keyDisplay: "Right ⌥", keyBehavior: .holdOrTap)
        assertEqual(handsFree.headline, "Now hands-free", "the second take is hands-free")
        assertTrue(handsFree.instruction.contains("Tap Right ⌥ once"), "hands-free starts with a tap")
    }
}

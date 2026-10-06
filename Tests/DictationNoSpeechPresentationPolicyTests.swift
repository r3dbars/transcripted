import Foundation

func testDictationNoSpeechPresentationPolicy() {
    runSuite("Undecoded audio from a long take offers import without claiming speech certainty") {
        let message = DictationNoSpeechPresentationPolicy.message(
            trigger: "physical_key",
            reason: .audioNeedsRecovery,
            savedRecordingOffered: true
        )
        assertTrue(message.contains("did not become text"), "empty inference or stale converted samples should use honest recovery copy")
        assertTrue(message.contains(DictationSavedAudioActionCopy.transcribeTitle), "recovery should name the Transcribe It button on the message")
        assertFalse(message.contains("Capture →"), "don't send people to a menu that only shows while the app is in front")
        assertFalse(message.contains("Home"), "do not send users to a page that is now labeled Meetings")
        assertFalse(message.contains("No speech heard"), "audio activity must not be dismissed as silence")
    }

    runSuite("Undecoded audio from a short take just asks for another try") {
        let message = DictationNoSpeechPresentationPolicy.message(
            trigger: "physical_key",
            reason: .audioNeedsRecovery
        )
        assertEqual(message, "Didn't catch that. Try again.", "the audio is already gone, so say it plainly")
        assertFalse(message.contains(DictationSavedAudioActionCopy.transcribeTitle), "no button to name: nothing was kept")
        assertFalse(message.contains("saved"), "don't promise a recording that was deleted")
        assertFalse(message.contains("No speech heard"), "audio activity must not be dismissed as silence")
    }
    runSuite("DictationNoSpeechPresentationPolicy gives physical-key users direct recovery copy") {
        let message = DictationNoSpeechPresentationPolicy.message(trigger: "physical_key", shortcutMode: .pushToTalk)

        assertEqual(
            message,
            "No speech heard. Hold the dictation key while you talk.",
            "push-to-talk no-speech copy should explain the press-and-hold behavior"
        )
    }

    runSuite("DictationNoSpeechPresentationPolicy never tells hands-free users to hold a key") {
        assertEqual(
            DictationNoSpeechPresentationPolicy.message(trigger: "physical_key", shortcutMode: .handsFree),
            "No speech heard. Check your mic and try again.",
            "hands-free people had nothing to hold"
        )
        assertEqual(
            DictationNoSpeechPresentationPolicy.message(trigger: "physical_key"),
            "No speech heard. Check your mic and try again.",
            "when the shortcut isn't known, don't guess push-to-talk"
        )
    }

    runSuite("DictationNoSpeechPresentationPolicy gives menu users a direct retry path") {
        let message = DictationNoSpeechPresentationPolicy.message(trigger: "menu")

        assertEqual(
            message,
            "No speech heard. Start over and speak a little longer.",
            "non-physical-key dictation should explain the next retry action"
        )
    }

    runSuite("DictationNoSpeechPresentationPolicy names a mic that sent only silence") {
        let muted = DictationNoSpeechPresentationPolicy.message(
            trigger: "physical_key",
            shortcutMode: .pushToTalk,
            silentMicName: "BEACN Mic"
        )
        assertEqual(
            muted,
            "BEACN Mic sent only silence. If it has a mute button or switch, turn it off, or pick another mic in Settings.",
            "all-zero audio is a muted mic, not a quiet speaker, so say which mic and what to check"
        )
        assertFalse(muted.contains("Hold the dictation key"), "they held the key; the mic is the problem")
        assertTrue(
            DictationNoSpeechPresentationPolicy.message(trigger: "menu", silentMicName: "  ").hasPrefix("Your microphone sent only silence."),
            "a blank device name still reads naturally"
        )
        assertEqual(
            DictationNoSpeechPresentationPolicy.message(trigger: "menu", reason: .recordingTooShort, silentMicName: "BEACN Mic"),
            DictationNoSpeechPresentationPolicy.message(trigger: "menu", reason: .recordingTooShort),
            "only plain no-speech takes the silent-mic copy"
        )
    }

    runSuite("DictationNoSpeechPresentationPolicy separates too-short recordings from silence") {
        let message = DictationNoSpeechPresentationPolicy.message(
            trigger: "menu",
            reason: .recordingTooShort
        )

        assertEqual(
            message,
            "Only a moment of audio came through. Try again, and if it keeps happening, check your microphone.",
            "too-short dictation after a real press points at the mic instead of blaming silence or the user"
        )
    }
}

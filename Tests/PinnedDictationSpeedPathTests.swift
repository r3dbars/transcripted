import Foundation

func testPinnedDictationSpeedPath() {
    let macMic = DictationAudioDevice(id: 3, name: "MacBook Air Microphone", transport: .builtIn, inputChannelCount: 1, uid: "BuiltInMicrophoneDevice")
    let usbMic = DictationAudioDevice(id: 4, name: "Shure MV7", transport: .usb, inputChannelCount: 1, uid: "mv7")

    runSuite("Only takes that say something about the mic are scored") {
        assertEqual(PinnedDictationSpeedPath.outcome(text: "hello there", emptyReason: nil), .hadWords)
        assertEqual(PinnedDictationSpeedPath.outcome(text: nil, emptyReason: .noSpeech), .empty, "nothing heard on a held key")
        assertEqual(
            PinnedDictationSpeedPath.outcome(text: nil, emptyReason: .audioNeedsRecovery),
            .empty,
            "signal with no words is what the M1 Air's other take looked like"
        )
        assertEqual(
            PinnedDictationSpeedPath.outcome(text: nil, emptyReason: .otherLanguage),
            .hadWords,
            "held-back text still means the mic heard words"
        )
        assertEqual(PinnedDictationSpeedPath.outcome(text: "  ", emptyReason: .noSpeech), .empty)
        assertNil(PinnedDictationSpeedPath.outcome(text: nil, emptyReason: .recordingTooShort), "a tap says nothing about the mic")
        assertNil(
            PinnedDictationSpeedPath.outcome(text: nil, emptyReason: .recordingTooShort, heldSeconds: 1.2),
            "still a mis-tap"
        )
        assertEqual(
            PinnedDictationSpeedPath.outcome(text: nil, emptyReason: .recordingTooShort, heldSeconds: 1.5),
            .empty,
            "held past a mis-tap and the recorder delivered almost nothing"
        )
        assertEqual(
            PinnedDictationSpeedPath.outcome(text: nil, emptyReason: .recordingTooShort, heldSeconds: 6),
            .empty
        )
        assertEqual(
            PinnedDictationSpeedPath.outcome(text: "hello", emptyReason: .recordingTooShort, heldSeconds: 6),
            .hadWords
        )
        assertNil(
            PinnedDictationSpeedPath.outcome(text: nil, emptyReason: .modelFailure, heldSeconds: 6),
            "a long take the model failed on still says nothing about the mic"
        )
        assertNil(PinnedDictationSpeedPath.outcome(text: nil, emptyReason: .modelFailure), "the model failed, not the mic")
        assertNil(PinnedDictationSpeedPath.outcome(text: nil, emptyReason: nil), "cancelled")
    }

    runSuite("Two empty takes in a row move the mic back to the engine; words reset the count") {
        let once = PinnedDictationSpeedPath.scored(.empty, previous: nil, appVersion: "1.1.67")
        assertEqual(once.emptyTakesInARow, 1)
        assertFalse(once.turnedOff, "one press with nothing said is common")

        let twice = PinnedDictationSpeedPath.scored(.empty, previous: once, appVersion: "1.1.67")
        assertEqual(twice.emptyTakesInARow, 2)
        assertTrue(twice.turnedOff)

        let reset = PinnedDictationSpeedPath.scored(.hadWords, previous: once, appVersion: "1.1.67")
        assertEqual(reset.emptyTakesInARow, 0)
        assertFalse(PinnedDictationSpeedPath.scored(.empty, previous: reset, appVersion: "1.1.67").turnedOff)

        let staysOff = PinnedDictationSpeedPath.scored(.hadWords, previous: twice, appVersion: "1.1.67")
        assertTrue(staysOff.turnedOff, "engine takes are never scored, so a moved mic stays moved for the version")

        let nextVersion = PinnedDictationSpeedPath.scored(.empty, previous: twice, appVersion: "1.1.68")
        assertEqual(nextVersion, .init(appVersion: "1.1.68", emptyTakesInARow: 1, turnedOff: false), "a new version tries the recorder again")
    }

    runSuite("The move is stored per mic and per app version") {
        let suiteName = "PinnedDictationSpeedPathTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(PinnedDictationSpeedPath.isTurnedOff(for: macMic, userDefaults: defaults, appVersion: "1.1.67"))
        let first = PinnedDictationSpeedPath.record(.empty, for: macMic, userDefaults: defaults, appVersion: "1.1.67")
        assertFalse(first.turnedOffNow)
        assertFalse(PinnedDictationSpeedPath.isTurnedOff(for: macMic, userDefaults: defaults, appVersion: "1.1.67"))

        let second = PinnedDictationSpeedPath.record(.empty, for: macMic, userDefaults: defaults, appVersion: "1.1.67")
        assertTrue(second.turnedOffNow, "the second empty take is the one that moves the mic")
        assertTrue(PinnedDictationSpeedPath.isTurnedOff(for: macMic, userDefaults: defaults, appVersion: "1.1.67"))
        assertFalse(PinnedDictationSpeedPath.isTurnedOff(for: usbMic, userDefaults: defaults, appVersion: "1.1.67"), "other mics keep the recorder")
        assertFalse(
            PinnedDictationSpeedPath.isTurnedOff(for: macMic, userDefaults: defaults, appVersion: "1.1.68"),
            "an update tries the recorder again"
        )

        let third = PinnedDictationSpeedPath.record(.empty, for: macMic, userDefaults: defaults, appVersion: "1.1.67")
        assertFalse(third.turnedOffNow, "reported once, not on every later take")
    }

    runSuite("An input with no UID is keyed by its id") {
        let noUID = DictationAudioDevice(id: 9, name: "Mic", transport: .usb, inputChannelCount: 1)
        assertEqual(PinnedDictationSpeedPath.key(for: noUID), "id:9")
        assertEqual(PinnedDictationSpeedPath.key(for: macMic), "BuiltInMicrophoneDevice")
    }

    runSuite("The report carries format and health counts, never the mic's name") {
        let take = PinnedDictationSpeedPathTake(
            input: macMic,
            channelCount: 1,
            sampleRate: 48_000,
            restarts: 0,
            gaps: 3,
            droppedCallbacks: 40
        )
        assertEqual(
            take.reportContext,
            ["input_channels": "1", "input_rate_hz": "48000", "restarts": "0", "gaps": "3", "dropped_callbacks": "40"]
        )
        assertFalse(take.reportContext.values.contains(macMic.name))
        assertFalse(take.reportContext.values.contains("BuiltInMicrophoneDevice"))
    }
}

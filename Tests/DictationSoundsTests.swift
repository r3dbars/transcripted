// DictationSoundsTests.swift
//
// Three kinds of coverage live in this file; they are NOT the same strength of proof:
//
// REAL BEHAVIORAL COVERAGE (compiled): the UISoundPreferences suites and the
// "AppSoundPlayer uses expected bundled files only" / "playback entrypoints are best
// effort" suites exercise Foundation-pure logic compiled into the fast-test runner —
// the default-on preference, explicit get/set, and the per-cue bundled-file-name and
// volume-multiplier mapping. These run the real logic and assert real outputs.
//
// REAL STRUCTURAL RESOURCE CONTRACT (NOT compiled, but a real on-disk fact): the
// "Bundled sound files are exactly the active cue set" suite lists Resources/Sounds on
// disk and asserts the exact file set. Resources/Sounds is copied wholesale into the app
// bundle, so this is a genuine resource invariant (no unused/surprise cues ship) — it
// checks the real filesystem, not source text.
//
// IMPLEMENTATION-PINNING PRESENCE PINS (NOT compiled): the "Stop click plays on Stop"
// suite reads DictationSessionController.swift as TEXT and pins that the stop cue is
// queued once, before the transcription task, so it acknowledges Stop without waiting
// on paste. The "Start click answers the key press" suite pins that the fast path
// queues the start cue before the mic start task, and that it plays once per session.
// The "Feedback submit paths stay silent" suite reads Sources/UI/Shared/TranscriptedSupportActions.swift and
// Sources/UI/Settings/TranscriptedSettingsView.swift as TEXT and asserts ABSENCE of
// `AppSoundPlayer.shared.play(` and `NSSound.beep()` on the feedback
// paths. These SwiftUI/AppKit sources are NOT compiled into this Foundation-only runner,
// so these greps pin source structure, not runtime behavior: they guard the product rule
// that submitting feedback opens email silently (no app cue, no system beep). If you
// rename those functions or change how feedback playback is wired, update both the source
// and these presence pins together.

import Foundation

func testDictationSounds() {
    runSuite("UISoundPreferences defaults to enabled") {
        let key = "enableUISounds"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            restoreUserDefault(original, forKey: key)
        }

        UserDefaults.standard.removeObject(forKey: key)
        assertTrue(UISoundPreferences.isEnabled(), "unset preference should default to enabled")
    }

    runSuite("UISoundPreferences respects explicit values") {
        let key = "enableUISounds"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            restoreUserDefault(original, forKey: key)
        }

        UISoundPreferences.setEnabled(false)
        assertFalse(UISoundPreferences.isEnabled(), "explicit false should disable sounds")

        UISoundPreferences.setEnabled(true)
        assertTrue(UISoundPreferences.isEnabled(), "explicit true should enable sounds")
    }

    runSuite("UISoundPreferences reads the Mac's interface-sounds switch") {
        let suiteName = "DictationSoundsTests.systemInterfaceSounds"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assertTrue(false, "test defaults suite should open")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(0, forKey: "com.apple.sound.uiaudio.enabled")
        assertFalse(UISoundPreferences.systemInterfaceSoundsEnabled(userDefaults: defaults), "0 turns interface sounds off")

        defaults.set(1, forKey: "com.apple.sound.uiaudio.enabled")
        assertTrue(UISoundPreferences.systemInterfaceSoundsEnabled(userDefaults: defaults), "1 keeps interface sounds on")
    }

    runSuite("AppSoundPlayer uses expected bundled files only") {
        assertEqual(AppSoundPlayer.Cue.dictationStart.bundledFileName, "dictation-start.caf", "start cue file")
        assertEqual(AppSoundPlayer.Cue.dictationStop.bundledFileName, "dictation-stop.caf", "stop cue file")
        assertEqual(AppSoundPlayer.Cue.noSpeech.bundledFileName, "dictation-cancelled.wav", "no speech must not reuse the stop click")
        assertEqual(AppSoundPlayer.Cue.meetingTranscriptComplete.bundledFileName, "meeting-transcript-complete.mp3", "meeting cue file")
        assertEqual(AppSoundPlayer.Cue.dictationCancelled.bundledFileName, "dictation-cancelled.wav", "cancel cue uses the bundled soft cue, never a system sound")
        assertEqual(AppSoundPlayer.Cue.dictationStart.volumeMultiplier, TranscriptedConstants.dictationClickCueVolumeMultiplier, "start cue volume")
        assertEqual(AppSoundPlayer.Cue.dictationStop.volumeMultiplier, TranscriptedConstants.dictationClickCueVolumeMultiplier, "stop cue volume matches start")
        assertEqual(TranscriptedConstants.overlayCueVolume * TranscriptedConstants.dictationClickCueVolumeMultiplier, 0.35, "clicks play at 35%")
        assertEqual(AppSoundPlayer.Cue.noSpeech.volumeMultiplier, TranscriptedConstants.noSpeechCueVolumeMultiplier, "no speech cue volume")
        assertEqual(AppSoundPlayer.Cue.menuHover.bundledFileName, "menu-hover.wav", "menu hover tick file")
        assertTrue(
            AppSoundPlayer.Cue.menuHover.volumeMultiplier < TranscriptedConstants.dictationClickCueVolumeMultiplier,
            "the hover tick stays quieter than the dictation clicks"
        )
        assertTrue(AppSoundPlayer.Cue.menuHover.followsSystemInterfaceSounds, "hover tick follows the Mac's interface-sounds switch")
        assertEqual(AppSoundPlayer.Cue.menuRowHover.bundledFileName, "menu-row-hover.wav", "menu row hover tick file")
        assertTrue(
            AppSoundPlayer.Cue.menuRowHover.volumeMultiplier < AppSoundPlayer.Cue.menuHover.volumeMultiplier,
            "the rows tick softer than the buttons"
        )
        assertTrue(AppSoundPlayer.Cue.menuRowHover.followsSystemInterfaceSounds, "row tick follows the Mac's interface-sounds switch")
        assertEqual(AppSoundPlayer.Cue.menuPress.bundledFileName, "menu-press.wav", "menu press click file")
        assertTrue(
            AppSoundPlayer.Cue.menuPress.volumeMultiplier < TranscriptedConstants.dictationClickCueVolumeMultiplier,
            "the press click stays quieter than the dictation clicks"
        )
        assertTrue(AppSoundPlayer.Cue.menuPress.followsSystemInterfaceSounds, "press click follows the Mac's interface-sounds switch")
        assertFalse(AppSoundPlayer.Cue.dictationStart.followsSystemInterfaceSounds, "dictation clicks keep the app's own sound switch only")
    }

    runSuite("AppSoundPlayer drops cues that are a second stale") {
        assertFalse(AppSoundPlayer.isStale(requestedAt: 100, now: 100), "immediate cue plays")
        assertFalse(AppSoundPlayer.isStale(requestedAt: 100, now: 100.9), "cue under a second late still plays")
        assertTrue(AppSoundPlayer.isStale(requestedAt: 100, now: 101), "cue a full second late is dropped")
        assertTrue(AppSoundPlayer.isStale(requestedAt: 100, now: 104), "cue stuck behind a slow device is dropped")
    }

    runSuite("Bundled sound files are exactly the active cue set") {
        let soundsDirectory = repoRoot()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        let soundFiles = ((try? FileManager.default.contentsOfDirectory(
            at: soundsDirectory,
            includingPropertiesForKeys: nil
        )) ?? [])
            .map(\.lastPathComponent)
            .sorted()

        assertEqual(
            soundFiles,
            [
                "README.md",
                "dictation-cancelled.wav",
                "dictation-start.caf",
                "dictation-stop.caf",
                "meeting-transcript-complete.mp3",
                "menu-hover.wav",
                "menu-press.wav",
                "menu-row-hover.wav",
            ],
            "Resources/Sounds is copied wholesale, so unused surprise cues should not ship"
        )
    }

    runSuite("AppSoundPlayer playback entrypoints are best effort") {
        let key = "enableUISounds"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            restoreUserDefault(original, forKey: key)
        }

        UISoundPreferences.setEnabled(false)
        AppSoundPlayer.shared.play(.dictationStart)
        AppSoundPlayer.shared.play(.meetingTranscriptComplete, respectingPreferences: false)
    }

    runSuite("Stop click plays once the mic stops, before transcription and paste") {
        let controller = readRepoTextFile("Sources/UI/Overlay/DictationSessionController.swift")
        let afterMicStop = sourceSlice(
            in: controller,
            from: "await appState.sttRouter.stopRecording()\n            stopTiming.micStoppedAt",
            to: "stopTiming.snapshotStartedAt = CFAbsoluteTimeGetCurrent()"
        )
        assertTrue(
            afterMicStop.contains("AppSoundPlayer.shared.play(.dictationStop)"),
            "the stop click must play after the mic stops (so speakers can't leak it into the take) and before the snapshot and transcription"
        )
        assertEqual(
            controller.components(separatedBy: "AppSoundPlayer.shared.play(.dictationStop)").count - 1,
            1,
            "Stop is the only end-of-take click; no second chime after paste"
        )
    }

    runSuite("Start click answers the key press on the fast path, once") {
        let controller = readRepoTextFile("Sources/UI/Overlay/DictationSessionController.swift")
        let fastPathBeforeMicStart = sourceSlice(
            in: controller,
            from: "case .skipLoadingAndStartRecording:",
            to: "recordingStartRetryTask = Task"
        )
        assertTrue(
            fastPathBeforeMicStart.contains("DictationStartCuePolicy.playsOnKeyPress(")
                && fastPathBeforeMicStart.contains("playStartCueOnce()"),
            "the start click must be queued before the mic start task, so it doesn't wait on the mic"
        )
        assertEqual(
            controller.components(separatedBy: "AppSoundPlayer.shared.play(.dictationStart)").count - 1,
            1,
            "every start click goes through playStartCueOnce, so a session never clicks twice"
        )
    }

    runSuite("Feedback submit paths stay silent") {
        let supportActions = readRepoTextFile("Sources/UI/Shared/TranscriptedSupportActions.swift")
        assertFalse(
            supportActions.contains("AppSoundPlayer.shared.play("),
            "support email actions should not play any UI sound cue"
        )
        assertFalse(
            supportActions.contains("NSSound.beep()"),
            "support email actions should not fall back to a system beep"
        )

        let settingsView = readRepoTextFile("Sources/UI/Settings/TranscriptedSettingsView.swift")
        let homeFeedbackSubmit = sourceSlice(
            in: settingsView,
            from: "private func submitHomeFeedback",
            to: "private func flashCopied"
        )
        assertFalse(
            homeFeedbackSubmit.contains("AppSoundPlayer.shared.play"),
            "Home contextual feedback should open email without an app sound"
        )
        assertFalse(
            homeFeedbackSubmit.contains("NSSound.beep()"),
            "Home contextual feedback should not use a system beep on submit failure"
        )
    }
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func restoreUserDefault(_ value: Any?, forKey key: String) {
    if let value {
        UserDefaults.standard.set(value, forKey: key)
    } else {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

private func readRepoTextFile(_ relativePath: String) -> String {
    let url = repoRoot().appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func sourceSlice(in contents: String, from startMarker: String, to endMarker: String) -> String {
    guard let start = contents.range(of: startMarker) else { return "" }
    let remainder = contents[start.lowerBound...]
    guard let end = remainder.range(of: endMarker) else { return String(remainder) }
    return String(remainder[..<end.lowerBound])
}

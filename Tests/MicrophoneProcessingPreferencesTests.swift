import Foundation

func testMicrophoneProcessingPreferences() {
    runSuite("MicrophoneProcessingPreferences defaults to software autogain") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            MicrophoneProcessingPreferences.mode(userDefaults: defaults),
            .softwareAGC,
            "Default mode should keep the existing meeting quiet-mic recovery behavior"
        )
        assertEqual(
            MicrophoneProcessingPreferences.isVoiceProcessingEnabled(userDefaults: defaults),
            false,
            "VPIO toggle should default to false so existing users land on no-Zoom-ducking behavior"
        )
        assertEqual(
            MicrophoneProcessingPreferences.isSoftwareAutogainEnabled(userDefaults: defaults),
            true,
            "Software autogain should remain the default for existing users"
        )
    }

    runSuite("MicrophoneProcessingPreferences persists raw off mode") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MicrophoneProcessingPreferences.setMode(.none, userDefaults: defaults)

        assertEqual(
            MicrophoneProcessingPreferences.mode(userDefaults: defaults),
            .none,
            "Raw/off mode should persist through the injected defaults"
        )
        assertEqual(
            MicrophoneProcessingPreferences.isSoftwareAutogainEnabled(userDefaults: defaults),
            false,
            "Raw/off mode should disable Transcripted software AGC"
        )
        assertEqual(
            MicrophoneProcessingPreferences.isVoiceProcessingEnabled(userDefaults: defaults),
            false,
            "Raw/off mode should not arm Apple voice processing"
        )
    }

    runSuite("MicrophoneProcessingPreferences explains raw input for tuned USB mics") {
        assertTrue(
            MicrophoneProcessingMode.none.title.contains("no Transcripted gain"),
            "Raw/off picker title should explain that Transcripted gain is off"
        )
        assertTrue(
            MicrophoneProcessingMode.none.detail.contains("without software autogain"),
            "Raw/off help text should answer whether Transcripted applies software autogain"
        )
        assertTrue(
            MicrophoneProcessingMode.none.detail.contains("Blue Yeti"),
            "Raw/off help text should name tuned USB mics like Stephen's Blue Yeti"
        )
        assertTrue(
            MicrophoneProcessingMode.none.detail.contains("physical gain controls the level"),
            "Raw/off help text should make the user's hardware gain the control point"
        )
        assertTrue(
            MicrophoneProcessingMode.none.detail.contains("microphone.m4a"),
            "Raw/off help text should tie the setting to the saved mic track users inspect"
        )
    }

    runSuite("MicrophoneProcessingPreferences persists Apple voice processing mode") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MicrophoneProcessingPreferences.setMode(.appleVoiceProcessing, userDefaults: defaults)

        assertEqual(
            MicrophoneProcessingPreferences.isVoiceProcessingEnabled(userDefaults: defaults),
            true,
            "Apple voice processing mode should arm VPIO"
        )
        assertEqual(
            MicrophoneProcessingPreferences.isSoftwareAutogainEnabled(userDefaults: defaults),
            false,
            "Apple voice processing should not also run Transcripted software AGC"
        )
    }

    runSuite("MicrophoneProcessingPreferences legacy toggle maps to modes") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: MicrophoneProcessingPreferences.voiceProcessingEnabledKey)

        assertEqual(
            MicrophoneProcessingPreferences.mode(userDefaults: defaults),
            .appleVoiceProcessing,
            "Users who already opted into VPIO should keep that behavior"
        )

        MicrophoneProcessingPreferences.setVoiceProcessingEnabled(false, userDefaults: defaults)

        assertEqual(
            MicrophoneProcessingPreferences.mode(userDefaults: defaults),
            .softwareAGC,
            "The compatibility setter should preserve the old false == default software AGC meaning"
        )
    }

    runSuite("MicrophoneProcessingPreferences explicit mode wins over legacy toggle") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: MicrophoneProcessingPreferences.voiceProcessingEnabledKey)
        MicrophoneProcessingPreferences.setMode(.none, userDefaults: defaults)

        assertEqual(
            MicrophoneProcessingPreferences.mode(userDefaults: defaults),
            .none,
            "Once the new mode key exists it should be the source of truth"
        )
    }

    runSuite("A Boost saved before 1.1.63 moves back to software autogain once") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: MicrophoneProcessingPreferences.voiceProcessingEnabledKey)
        assertTrue(
            MicrophoneProcessingPreferences.migrateBoostedVoiceProcessingIfNeeded(userDefaults: defaults),
            "A saved legacy Boost must be migrated"
        )
        assertEqual(
            MicrophoneProcessingPreferences.mode(userDefaults: defaults),
            .softwareAGC,
            "Migration must land on the default software autogain"
        )
        assertEqual(
            MicrophoneProcessingPreferences.isVoiceProcessingEnabled(userDefaults: defaults),
            false,
            "No later meeting or dictation may arm VPIO after migration"
        )
        assertTrue(
            MicrophoneProcessingPreferences.showsBoostMigrationNote(userDefaults: defaults),
            "Migrated users must see why their setting changed"
        )

        MicrophoneProcessingPreferences.setMode(.appleVoiceProcessing, userDefaults: defaults)
        assertFalse(
            MicrophoneProcessingPreferences.showsBoostMigrationNote(userDefaults: defaults),
            "Picking a mode again answers the note"
        )
        assertFalse(
            MicrophoneProcessingPreferences.migrateBoostedVoiceProcessingIfNeeded(userDefaults: defaults),
            "A deliberate choice after the migration must never be undone"
        )
        assertEqual(
            MicrophoneProcessingPreferences.mode(userDefaults: defaults),
            .appleVoiceProcessing,
            "The re-picked mode must stick"
        )
    }

    runSuite("Boost migration leaves other modes alone and shows no note") {
        for mode in [MicrophoneProcessingMode.none, .softwareAGC] {
            let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            MicrophoneProcessingPreferences.setMode(mode, userDefaults: defaults)
            assertFalse(
                MicrophoneProcessingPreferences.migrateBoostedVoiceProcessingIfNeeded(userDefaults: defaults),
                "\(mode.rawValue) must not be migrated"
            )
            assertEqual(MicrophoneProcessingPreferences.mode(userDefaults: defaults), mode, "\(mode.rawValue) must be kept")
            assertFalse(
                MicrophoneProcessingPreferences.showsBoostMigrationNote(userDefaults: defaults),
                "\(mode.rawValue) users have nothing to be told"
            )
        }

        let (fresh, freshSuite) = makeMicrophoneProcessingDefaults()
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        assertFalse(
            MicrophoneProcessingPreferences.migrateBoostedVoiceProcessingIfNeeded(userDefaults: fresh),
            "A fresh install has nothing to migrate"
        )
        MicrophoneProcessingPreferences.setMode(.appleVoiceProcessing, userDefaults: fresh)
        assertFalse(
            MicrophoneProcessingPreferences.migrateBoostedVoiceProcessingIfNeeded(userDefaults: fresh),
            "The migration runs once per install, never on a later launch"
        )
    }

    runSuite("Accepting Boost Mic in a meeting never saves the mode") {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let bridge = (try? String(contentsOf: root.appendingPathComponent("Sources/Meeting/MeetingCaptureBridge.swift"), encoding: .utf8)) ?? ""
        guard let start = bridge.range(of: "    func armVoiceProcessingForActiveRecording(") else {
            assertTrue(false, "the Boost Mic arm entry point must exist")
            return
        }
        let end = bridge.range(of: "\n    }\n", range: start.upperBound..<bridge.endIndex)?.upperBound ?? bridge.endIndex
        let body = String(bridge[start.lowerBound..<end])
        assertTrue(body.contains("audio.restartCaptureForProcessingChange()"), "Boost must still arm VPIO for the live meeting")
        assertFalse(body.contains("MicrophoneProcessingPreferences"), "Boost must not save the mode for later meetings")
        assertTrue(
            body.contains("callAppIsUsingMicrophone()"),
            "A call app that is open but off the mic must not block Boost; one on the mic must"
        )
        assertTrue(
            body.contains("try? await Task.sleep(nanoseconds: retryDelayNanoseconds)"),
            "A Boost accepted during mic recovery waits for it instead of being dropped"
        )
    }

    runSuite("Boost mic next meeting lasts one meeting and quiets older hints") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(MicrophoneProcessingPreferences.isBoostRequestedForNextMeeting(userDefaults: defaults))
        assertTrue(
            MicrophoneProcessingPreferences.micBoostHintsHiddenThrough(userDefaults: defaults) == nil,
            "Nothing is hidden until the user answers a hint"
        )

        let before = Date()
        MicrophoneProcessingPreferences.requestBoostForNextMeeting(userDefaults: defaults)
        assertTrue(MicrophoneProcessingPreferences.isBoostRequestedForNextMeeting(userDefaults: defaults))
        assertEqual(
            MicrophoneProcessingPreferences.mode(userDefaults: defaults),
            .softwareAGC,
            "Asking for one boosted meeting must not save Apple voice processing"
        )
        let hiddenThrough = MicrophoneProcessingPreferences.micBoostHintsHiddenThrough(userDefaults: defaults)
        assertTrue(hiddenThrough.map { $0 >= before } ?? false, "Rows saved so far stop hinting")

        MicrophoneProcessingPreferences.hideMicBoostHints(
            through: before.addingTimeInterval(-3600),
            userDefaults: defaults
        )
        assertEqual(
            MicrophoneProcessingPreferences.micBoostHintsHiddenThrough(userDefaults: defaults),
            hiddenThrough,
            "The hidden-through moment never moves back"
        )

        MicrophoneProcessingPreferences.clearNextMeetingBoostRequest(userDefaults: defaults)
        assertFalse(
            MicrophoneProcessingPreferences.isBoostRequestedForNextMeeting(userDefaults: defaults),
            "The boost ends once a meeting started with it"
        )
    }

    runSuite("Boost migration also quiets hints on meetings saved before it") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        MicrophoneProcessingPreferences.setMode(.appleVoiceProcessing, userDefaults: defaults)
        let before = Date()
        assertTrue(MicrophoneProcessingPreferences.migrateBoostedVoiceProcessingIfNeeded(userDefaults: defaults))
        assertTrue(
            MicrophoneProcessingPreferences.micBoostHintsHiddenThrough(userDefaults: defaults).map { $0 >= before } ?? false,
            "Moving off a saved boost must not bring the Home hint back on old rows"
        )
    }

    runSuite("Only a successful meeting start uses up Boost mic next meeting") {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let bridge = (try? String(contentsOf: root.appendingPathComponent("Sources/Meeting/MeetingCaptureBridge.swift"), encoding: .utf8)) ?? ""
        assertTrue(
            bridge.contains("audio.enableVoiceProcessing = micProcessingMode.usesAppleVoiceProcessing || boostRequestedForThisMeeting"),
            "A requested boost arms voice processing for the meeting that starts"
        )
        assertTrue(
            bridge.contains("if started, boostRequestedForThisMeeting {\n            MicrophoneProcessingPreferences.clearNextMeetingBoostRequest()"),
            "A failed start keeps the request for the next try"
        )
        let settings = (try? String(contentsOf: root.appendingPathComponent("Sources/UI/Settings/TranscriptedSettingsView.swift"), encoding: .utf8)) ?? ""
        assertFalse(
            settings.contains("MicrophoneProcessingPreferences.setVoiceProcessingEnabled(true)"),
            "The Home row must not save Apple voice processing for every meeting"
        )
    }

    runSuite("MicrophoneProcessingPreferences uses stable storage keys") {
        // Lock the on-disk key so future refactors don't silently invalidate
        // existing users' preferences.
        assertEqual(
            MicrophoneProcessingPreferences.modeKey,
            "meeting-mic-processing-mode",
            "Mode storage key must remain stable across releases"
        )
        assertEqual(
            MicrophoneProcessingPreferences.voiceProcessingEnabledKey,
            "meeting-mic-voice-processing-enabled",
            "Legacy VPIO storage key must remain readable across releases"
        )
        assertEqual(
            MicrophoneProcessingPreferences.boostMigrationDoneKey,
            "meeting-mic-processing-boost-migration-done",
            "The one-time Boost migration must never rerun after a rename"
        )
        assertEqual(
            MicrophoneProcessingPreferences.nextMeetingBoostKey,
            "meeting-mic-processing-boost-next-meeting",
            "A pending one-meeting boost must survive an update"
        )
    }
}

private func makeMicrophoneProcessingDefaults() -> (UserDefaults, String) {
    let suiteName = "MicrophoneProcessingPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

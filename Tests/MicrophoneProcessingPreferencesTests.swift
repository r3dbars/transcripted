import Foundation

@MainActor
func testMicrophoneProcessingPreferences() async {
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

    await runSuite("Accepting Boost Mic arms voice processing for the live meeting") {
        let capture = FakeBoostCapture()
        assertEqual(await capture.arm(), .armed, "a plain boost applies")
        assertEqual(capture.restartCount, 1, "Boost must restart the live capture so voice processing applies now")
        assertTrue(capture.sleeps.isEmpty, "nothing to wait for")
        assertTrue(capture.watchedGenerations.isEmpty, "no call app to watch")

        let pinned = FakeBoostCapture()
        pinned.recordsThroughPinnedMicrophone = true
        assertEqual(await pinned.arm(), .notApplied, "the pinned Mac-mic recorder can't host voice processing")
        assertEqual(pinned.restartCount, 0, "the pinned recorder is left alone")
    }

    await runSuite("A call app on the mic blocks Boost; one open but off the mic doesn't") {
        let onMic = FakeBoostCapture()
        onMic.suppressedForSharing = true
        onMic.callAppOnMicrophone = true
        assertEqual(await onMic.arm(), .callAppUsingMicrophone, "a call app on the mic keeps the mic shared")
        assertEqual(onMic.restartCount, 0, "the call app's mic is not touched")
        assertTrue(onMic.suppressedForSharing, "sharing stays on")

        let helperOnMic = FakeBoostCapture()
        helperOnMic.callAppOnMicrophone = true
        assertEqual(await helperOnMic.arm(), .callAppUsingMicrophone, "the mic is scanned even with nothing latched")

        let openOffMic = FakeBoostCapture()
        openOffMic.generation = 7
        openOffMic.suppressedForSharing = true
        assertEqual(await openOffMic.arm(), .armed, "a call app left open but off the mic must not block Boost")
        assertFalse(openOffMic.suppressedForSharing, "the boost looks past the open call app")
        assertEqual(openOffMic.watchedGenerations, [7], "a watch hands the mic back if that app joins a call")
    }

    await runSuite("A call app launched during the meeting blocks Boost") {
        let launched = FakeBoostCapture()
        launched.callAppLaunched = true
        assertEqual(await launched.arm(), .callAppUsingMicrophone, "a call app launched mid-meeting is probably joining")
        assertEqual(launched.scanCount, 0, "no scan can talk the boost past that latch")
        assertEqual(launched.restartCount, 0, "Boost must not undo the latch")

        let launchedDuringScan = FakeBoostCapture()
        launchedDuringScan.onScan = { launchedDuringScan.callAppLaunched = true }
        assertEqual(await launchedDuringScan.arm(), .callAppUsingMicrophone, "a launch during the scan keeps the latch")
        assertEqual(launchedDuringScan.restartCount, 0, "Boost must not undo a latch set during its scan")

        let latchedDuringScan = FakeBoostCapture()
        latchedDuringScan.onScan = { latchedDuringScan.suppressedForSharing = true }
        assertEqual(await latchedDuringScan.arm(), .callAppUsingMicrophone, "sharing turned on during the scan wins")
    }

    await runSuite("A Boost accepted during mic recovery waits for it instead of being dropped") {
        let recovering = FakeBoostCapture()
        recovering.restartResults = [false, false, true]
        assertEqual(await recovering.arm(retries: 5, delay: 42), .armed, "the boost lands once recovery ends")
        assertEqual(recovering.sleeps, [42, 42], "it waits between tries")

        let neverRecovers = FakeBoostCapture()
        neverRecovers.suppressedForSharing = true
        neverRecovers.restartResults = [false, false, false]
        assertEqual(await neverRecovers.arm(retries: 2, delay: 1), .notApplied, "it gives up after the retries")
        assertEqual(neverRecovers.restartCount, 3, "one try plus the retries")
        assertEqual(neverRecovers.sleeps.count, 2, "no wait after the last try")
        assertTrue(neverRecovers.suppressedForSharing, "a boost that never applied hands the mic back to the open call app")
        assertTrue(neverRecovers.watchedGenerations.isEmpty, "no watch for a boost that never applied")

        let stopped = FakeBoostCapture()
        stopped.restartResults = [false, true]
        stopped.onSleep = { stopped.recording = false }
        assertEqual(await stopped.arm(), .notApplied, "a recording that ended while waiting gets no boost")
        assertEqual(stopped.restartCount, 1, "no restart after the recording ended")

        let callJoinedWhileWaiting = FakeBoostCapture()
        callJoinedWhileWaiting.restartResults = [false, true]
        callJoinedWhileWaiting.onSleep = { callJoinedWhileWaiting.suppressedForSharing = true }
        assertEqual(await callJoinedWhileWaiting.arm(), .callAppUsingMicrophone, "a call app that latched while waiting wins")
        assertEqual(callJoinedWhileWaiting.restartCount, 1, "no restart once a call app latched")
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

    runSuite("A requested boost arms voice processing for the meeting that starts") {
        func plan(_ mode: MicrophoneProcessingMode, boost: Bool) -> MeetingMicStartPlan {
            MeetingMicStartPlan.make(
                processingMode: mode,
                boostRequestedForThisMeeting: boost,
                pinnedRecorderOn: false,
                microphoneChoice: .automatic
            )
        }
        assertTrue(plan(.softwareAGC, boost: true).enableVoiceProcessing, "the Home request adds voice processing to this meeting")
        assertTrue(plan(.none, boost: true).enableVoiceProcessing, "even on raw input")
        assertFalse(plan(.softwareAGC, boost: false).enableVoiceProcessing, "no request, no voice processing")
        assertTrue(plan(.appleVoiceProcessing, boost: false).enableVoiceProcessing, "the saved Apple mode still applies")
        assertEqual(
            plan(.softwareAGC, boost: true).enableSoftwareAGC,
            plan(.softwareAGC, boost: false).enableSoftwareAGC,
            "a boost doesn't change the saved autogain fallback"
        )
        assertFalse(plan(.none, boost: false).enableSoftwareAGC, "raw input never runs Transcripted autogain")
    }

    runSuite("Only a successful meeting start uses up Boost mic next meeting") {
        assertTrue(
            MeetingNextMeetingBoostPolicy.usesUpRequest(
                started: true, boostRequestedForThisMeeting: true, voiceProcessingSuppressedForMicrophoneSharing: false
            ),
            "a start that ran with the boost uses it up"
        )
        assertFalse(
            MeetingNextMeetingBoostPolicy.usesUpRequest(
                started: false, boostRequestedForThisMeeting: true, voiceProcessingSuppressedForMicrophoneSharing: false
            ),
            "a failed start keeps the request for the next try"
        )
        assertFalse(
            MeetingNextMeetingBoostPolicy.usesUpRequest(
                started: true, boostRequestedForThisMeeting: true, voiceProcessingSuppressedForMicrophoneSharing: true
            ),
            "a start where a call app kept the boost off keeps the request"
        )
        assertFalse(
            MeetingNextMeetingBoostPolicy.usesUpRequest(
                started: true, boostRequestedForThisMeeting: false, voiceProcessingSuppressedForMicrophoneSharing: false
            ),
            "nothing to use up without a request"
        )
    }

    await runSuite("The explicit Home request looks past an open call app that isn't on the mic") {
        var scans = 0
        func looksPast(running: Bool, boost: Bool, onMic: Bool, launchedDuringScan: Bool = false) async -> Bool {
            var launched = false
            return await MeetingNextMeetingBoostPolicy.looksPastOpenCallApp(
                callAppRunning: running,
                boostRequestedForThisMeeting: boost,
                callAppIsUsingMicrophone: {
                    scans += 1
                    if launchedDuringScan { launched = true }
                    return onMic
                },
                callAppLaunchedDuringRecording: { launched }
            )
        }
        assertTrue(await looksPast(running: true, boost: true, onMic: false), "an open call app off the mic doesn't block the request")
        assertFalse(await looksPast(running: true, boost: true, onMic: true), "a call app on the mic wins")
        assertFalse(
            await looksPast(running: true, boost: true, onMic: false, launchedDuringScan: true),
            "a call app launched during the scan keeps the latch"
        )
        scans = 0
        assertFalse(await looksPast(running: true, boost: false, onMic: false), "without a request an open call app wins")
        assertFalse(await looksPast(running: false, boost: true, onMic: false), "nothing to look past")
        assertEqual(scans, 0, "the mic is only scanned when it could change the answer")
    }

    runSuite("The Home Boost row never saves Apple voice processing") {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
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

/// Stands in for the live meeting capture behind `MeetingMicBoostArming`.
@MainActor
private final class FakeBoostCapture {
    var recordsThroughPinnedMicrophone = false
    var generation: UInt64 = 1
    var recording = true
    var callAppLaunched = false
    var callAppOnMicrophone = false
    var suppressedForSharing = false
    /// Restart outcomes in order; true once the queue runs out.
    var restartResults: [Bool] = []
    var onScan: () -> Void = {}
    var onSleep: () -> Void = {}
    private(set) var scanCount = 0
    private(set) var restartCount = 0
    private(set) var sleeps: [UInt64] = []
    private(set) var watchedGenerations: [UInt64] = []

    func arm(retries: Int = 15, delay: UInt64 = 1) async -> MeetingMicBoostArmResult {
        let arming = MeetingMicBoostArming(
            isRecordingThroughPinnedMicrophone: { self.recordsThroughPinnedMicrophone },
            currentRecordingSessionGeneration: { self.generation },
            isStillRecording: { self.recording && self.generation == $0 },
            callAppLaunchedDuringRecording: { self.callAppLaunched },
            callAppIsUsingMicrophone: {
                self.scanCount += 1
                self.onScan()
                return self.callAppOnMicrophone
            },
            voiceProcessingSuppressedForMicrophoneSharing: { self.suppressedForSharing },
            setVoiceProcessingSuppressedForMicrophoneSharing: { self.suppressedForSharing = $0 },
            restartCaptureForProcessingChange: {
                self.restartCount += 1
                return self.restartResults.isEmpty ? true : self.restartResults.removeFirst()
            },
            watchCallAppsWhileBoosted: { self.watchedGenerations.append($0) },
            sleep: {
                self.sleeps.append($0)
                self.onSleep()
            }
        )
        return await arming.arm(micRecoveryRetries: retries, retryDelayNanoseconds: delay)
    }
}

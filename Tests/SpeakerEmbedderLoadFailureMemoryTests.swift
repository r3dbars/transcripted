import Foundation

/// Promises of the memory that turns a failed background voiceprint load into
/// the WeSpeaker fallback on the next launch:
///   - with the model file present and no failure, the launch builds on the model
///     and its own database;
///   - after the model fails to load, the next launch on the same build uses
///     WeSpeaker and `speakers.sqlite`;
///   - a new app build or macOS version tries the model again;
///   - a later successful load clears the failure;
///   - a missing model file or the WeSpeaker choice always means `speakers.sqlite`.
func testSpeakerEmbedderLoadFailureMemory() {
    let model = "redimnet2-b4"

    func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "SpeakerEmbedderLoadFailureMemoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    func launchDatabase(_ memory: SpeakerEmbedderLoadFailureMemory, present: Bool = true) -> String {
        SpeakerVoiceprintSelection.databaseFileName(
            forEmbedderIdentifier: memory.launchModelIdentifier(chosen: model, modelFileIsPresent: present)
        )
    }

    runSuite("A present model that never failed gets its own database") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        let memory = SpeakerEmbedderLoadFailureMemory(userDefaults: d, buildKey: "100|macOS 26.1")
        assertEqual(memory.launchModelIdentifier(chosen: model, modelFileIsPresent: true), model, "model is used")
        assertEqual(launchDatabase(memory), "speakers_redimnet2-b4.sqlite", "its own database")
    }

    runSuite("After a failed load the next launch on the same build falls back to WeSpeaker and speakers.sqlite") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        SpeakerEmbedderLoadFailureMemory(userDefaults: d, buildKey: "100|macOS 26.1")
            .recordLoadEnded(model, loaded: false)

        let nextLaunch = SpeakerEmbedderLoadFailureMemory(userDefaults: d, buildKey: "100|macOS 26.1")
        assertTrue(nextLaunch.failedOnThisBuild(model), "failure is remembered")
        assertEqual(nextLaunch.launchModelIdentifier(chosen: model, modelFileIsPresent: true), nil, "WeSpeaker")
        assertEqual(launchDatabase(nextLaunch), "speakers.sqlite", "WeSpeaker's database, matching the fallback")
        assertFalse(nextLaunch.failedOnThisBuild("eres2net"), "other models are unaffected")
    }

    runSuite("A new app build or macOS version tries the model again") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        SpeakerEmbedderLoadFailureMemory(userDefaults: d, buildKey: "100|macOS 26.1")
            .recordLoadEnded(model, loaded: false)

        let newBuild = SpeakerEmbedderLoadFailureMemory(userDefaults: d, buildKey: "101|macOS 26.1")
        assertEqual(launchDatabase(newBuild), "speakers_redimnet2-b4.sqlite", "new app build retries")
        let newOS = SpeakerEmbedderLoadFailureMemory(userDefaults: d, buildKey: "100|macOS 26.2")
        assertEqual(launchDatabase(newOS), "speakers_redimnet2-b4.sqlite", "macOS update retries")
    }

    runSuite("A successful load clears an earlier failure") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        let memory = SpeakerEmbedderLoadFailureMemory(userDefaults: d, buildKey: "100|macOS 26.1")
        memory.recordLoadEnded(model, loaded: false)
        memory.recordLoadEnded(model, loaded: true)
        assertFalse(memory.failedOnThisBuild(model), "failure cleared")
        assertEqual(launchDatabase(memory), "speakers_redimnet2-b4.sqlite", "model used again")
        assertTrue(d.object(forKey: SpeakerEmbedderLoadFailureMemory.defaultsKey) == nil, "nothing left behind")
    }

    runSuite("A missing model file or the WeSpeaker choice always means speakers.sqlite") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        let memory = SpeakerEmbedderLoadFailureMemory(userDefaults: d, buildKey: "100|macOS 26.1")
        assertEqual(launchDatabase(memory, present: false), "speakers.sqlite", "no model file")
        assertEqual(memory.launchModelIdentifier(chosen: nil, modelFileIsPresent: true), nil, "WeSpeaker chosen")
    }

    runSuite("The build key changes with the app build and the macOS version") {
        let a = SpeakerEmbedderLoadFailureMemory.currentBuildKey(operatingSystemVersion: "Version 26.1")
        let b = SpeakerEmbedderLoadFailureMemory.currentBuildKey(operatingSystemVersion: "Version 26.2")
        assertTrue(a != b, "OS version is part of the key")
    }
}

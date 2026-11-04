import Foundation

func testAudioStoragePreferences() {
    runSuite("AudioStoragePreferences defaults to keeping compressed audio") {
        let (defaults, suiteName) = makeAudioStorageDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        assertEqual(
            AudioStoragePreferences.deleteAudioAfter(userDefaults: defaults),
            .never,
            "audio retention should default to never deleting retained compressed audio"
        )
    }

    runSuite("AudioStoragePreferences persists delete-after window") {
        let (defaults, suiteName) = makeAudioStorageDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        AudioStoragePreferences.setDeleteAudioAfter(.sevenDays, userDefaults: defaults)

        assertEqual(
            AudioStoragePreferences.deleteAudioAfter(userDefaults: defaults),
            .sevenDays,
            "explicit retention window should round-trip"
        )
    }

    runSuite("AudioStoragePreferences falls back from unknown values") {
        let (defaults, suiteName) = makeAudioStorageDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        defaults.set("soonish", forKey: AudioStoragePreferences.deleteAudioAfterKey)

        assertEqual(
            AudioStoragePreferences.deleteAudioAfter(userDefaults: defaults),
            .never,
            "unknown retention values should fail closed to keeping audio"
        )
    }

    runSuite("Saving a meeting audio window never changes the dictation audio window") {
        assertTrue(
            AudioStoragePreferences.deleteAudioAfterKey != AudioStoragePreferences.dictationAudioKeepKey,
            "the two settings must persist under different keys"
        )
        let dictationStarts: [DictationAudioKeepWindow?] = [nil] + DictationAudioKeepWindow.allCases.map(Optional.some)
        for dictationStart in dictationStarts {
            for meeting in AudioRetentionWindow.allCases {
                let (defaults, suiteName) = makeAudioStorageDefaults()
                defer { UserDefaults().removePersistentDomain(forName: suiteName) }
                if let dictationStart {
                    AudioStoragePreferences.setDictationAudioKeepWindow(dictationStart, userDefaults: defaults)
                }

                AudioStoragePreferences.setDeleteAudioAfter(meeting, userDefaults: defaults)

                assertEqual(AudioStoragePreferences.deleteAudioAfter(userDefaults: defaults), meeting)
                assertEqual(
                    AudioStoragePreferences.dictationAudioKeepWindow(userDefaults: defaults),
                    dictationStart ?? .thirtyDays,
                    "meeting \(meeting.rawValue) must leave dictation at \(dictationStart?.rawValue ?? "its unset 30-day default")"
                )
            }
        }
    }

    runSuite("Saving a dictation audio window never changes the meeting audio window") {
        let meetingStarts: [AudioRetentionWindow?] = [nil] + AudioRetentionWindow.allCases.map(Optional.some)
        for meetingStart in meetingStarts {
            for dictation in DictationAudioKeepWindow.allCases {
                let (defaults, suiteName) = makeAudioStorageDefaults()
                defer { UserDefaults().removePersistentDomain(forName: suiteName) }
                if let meetingStart {
                    AudioStoragePreferences.setDeleteAudioAfter(meetingStart, userDefaults: defaults)
                }

                AudioStoragePreferences.setDictationAudioKeepWindow(dictation, userDefaults: defaults)

                assertEqual(AudioStoragePreferences.dictationAudioKeepWindow(userDefaults: defaults), dictation)
                assertEqual(
                    AudioStoragePreferences.deleteAudioAfter(userDefaults: defaults),
                    meetingStart ?? .never,
                    "dictation \(dictation.rawValue) must leave meeting at \(meetingStart?.rawValue ?? "its unset Never default")"
                )
            }
        }
    }
}

private func makeAudioStorageDefaults() -> (UserDefaults, String) {
    let suiteName = "AudioStoragePreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

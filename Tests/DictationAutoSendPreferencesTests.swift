import Foundation

func testDictationAutoSendPreferences() {
    runSuite("DictationAutoSendPreferences defaults to disabled Enter") {
        let (defaults, suiteName) = makeAutoSendDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(DictationAutoSendPreferences.isEnabled(userDefaults: defaults), "auto enter should default off")
        assertEqual(DictationAutoSendPreferences.sendKey(userDefaults: defaults), .enter, "send key should default to Enter")
        assertEqual(DictationAutoSendPreferences.allowedBundleIDs(userDefaults: defaults), [], "allowed app list should default empty")
    }

    runSuite("DictationAutoSendPreferences persists enabled state and send key") {
        let (defaults, suiteName) = makeAutoSendDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DictationAutoSendPreferences.setEnabled(true, userDefaults: defaults)
        DictationAutoSendPreferences.setSendKey(.commandEnter, userDefaults: defaults)
        DictationAutoSendPreferences.setAllowedBundleIDs(["com.example.Chat", "com.example.Notes"], userDefaults: defaults)

        assertTrue(DictationAutoSendPreferences.isEnabled(userDefaults: defaults), "auto enter should read explicit enabled state")
        assertEqual(DictationAutoSendPreferences.sendKey(userDefaults: defaults), .commandEnter, "send key should read explicit Cmd+Enter")
        assertEqual(
            DictationAutoSendPreferences.allowedBundleIDs(userDefaults: defaults),
            ["com.example.Chat", "com.example.Notes"],
            "allowed app list should persist bundle IDs"
        )
    }

    runSuite("DictationAutoSendPreferences falls back from unknown send key") {
        let (defaults, suiteName) = makeAutoSendDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("space_laser", forKey: "dictationAutoEnterKey")

        assertEqual(DictationAutoSendPreferences.sendKey(userDefaults: defaults), .enter, "unknown send key should fall back to Enter")
    }

    runSuite("DictationAutoSendOutcome confirmation titles distinguish sent keys") {
        assertEqual(
            DictationAutoSendOutcome.sent(.enter).confirmationTitle,
            "Pasted + Enter",
            "sent Enter should make the fired key visible in the overlay confirmation"
        )
        assertEqual(
            DictationAutoSendOutcome.sent(.commandEnter).confirmationTitle,
            "Pasted + Cmd + Enter",
            "sent Cmd+Enter should make the fired key visible in the overlay confirmation"
        )
        assertNil(
            DictationAutoSendOutcome.disabled.confirmationTitle,
            "disabled Auto Enter should keep the plain pasted confirmation"
        )
        assertNil(
            DictationAutoSendOutcome.failed("Accessibility is off").confirmationTitle,
            "failed Auto Enter should route to the visible error path instead"
        )
    }

    runSuite("DictationAutoSendPolicy only sends after a real paste with text") {
        assertTrue(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                delivery: .pasted,
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "enabled pasted dictation with text should send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: false,
                delivery: .pasted,
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "disabled preference should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                delivery: .copied,
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "copied fallback should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                delivery: .pasted,
                text: "   \n",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "empty transcript should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                delivery: .pasted,
                text: "Too fast",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration - 0.01,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "very short accidental taps should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                delivery: .pasted,
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Notes",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "unselected apps should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                delivery: .pasted,
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: nil,
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "unknown source apps should not send"
        )
    }
}

private func makeAutoSendDefaults() -> (UserDefaults, String) {
    let suiteName = "DictationAutoSendPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

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
            DictationAutoSendOutcome.failed(.accessibilityMissing).confirmationTitle,
            "failed Auto Enter should route to the visible error path instead"
        )
    }

    runSuite("DictationAutoSendPolicy explains why Auto Enter was or was not expected") {
        let expected = DictationAutoSendPolicy.requestDecision(
            isEnabled: true,
            key: .commandEnter,
            text: "Send this",
            duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
            sourceBundleID: "com.example.Chat",
            allowedBundleIDs: ["com.example.Chat"]
        )
        assertEqual(
            expected,
            DictationAutoSendRequestDecision(expected: true, key: .commandEnter, blockReason: .none),
            "selected apps should expose an expected Command+Enter decision without app identity telemetry"
        )

        let featureOff = DictationAutoSendPolicy.requestDecision(
            isEnabled: false,
            key: .commandEnter,
            text: "Send this",
            duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
            sourceBundleID: "com.example.Chat",
            allowedBundleIDs: ["com.example.Chat"]
        )
        assertEqual(featureOff.blockReason, .featureOff, "disabled Auto Enter should have a coarse block reason")

        let appNotAllowed = DictationAutoSendPolicy.requestDecision(
            isEnabled: true,
            key: .enter,
            text: "Send this",
            duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
            sourceBundleID: "com.example.Notes",
            allowedBundleIDs: ["com.example.Chat"]
        )
        assertEqual(appNotAllowed.blockReason, .appNotAllowed, "unselected apps should have a coarse block reason")
    }

    runSuite("DictationAutoSendTelemetry distinguishes success, paste blocks, and send failures") {
        let request = DictationAutoSendRequestDecision(expected: true, key: .commandEnter, blockReason: .none)

        let success = DictationAutoSendTelemetry.snapshot(
            request: request,
            pasteOutcome: .pasted,
            sendOutcome: .sent(.commandEnter)
        )
        assertEqual(success.expected, true, "successful Auto Enter should preserve the expected denominator")
        assertEqual(success.blockReason, .none, "successful Auto Enter should not report a block")
        assertEqual(success.analyticsProperties["auto_send_key"], "command_enter", "telemetry should retain only the coarse key choice")

        let unconfirmed = DictationAutoSendTelemetry.snapshot(
            request: request,
            pasteOutcome: .copied("unconfirmed", reason: .pasteConfirmationUnavailable),
            sendOutcome: .disabled
        )
        assertEqual(unconfirmed.expected, true, "an eligible user configuration should remain expected when paste evidence blocks sending")
        assertEqual(unconfirmed.blockReason, .pasteConfirmationUnavailable, "the historical false-negative path should be queryable")

        let targetChanged = DictationAutoSendTelemetry.snapshot(
            request: request,
            pasteOutcome: .pasted,
            sendOutcome: .failed(.targetChanged)
        )
        assertEqual(targetChanged.blockReason, .targetChanged, "post-paste target changes should remain distinguishable")

        let featureOffRequest = DictationAutoSendRequestDecision(
            expected: false,
            key: .commandEnter,
            blockReason: .featureOff
        )
        let featureOff = DictationAutoSendTelemetry.snapshot(
            request: featureOffRequest,
            pasteOutcome: .pasted,
            sendOutcome: .disabled
        )
        assertEqual(featureOff.blockReason, .featureOff, "a disabled request should retain its real policy reason instead of looking cancelled")

        let cancelled = DictationAutoSendTelemetry.snapshot(
            request: request,
            pasteOutcome: .pasted,
            sendOutcome: .disabled
        )
        assertEqual(cancelled.blockReason, .cancelled, "only an expected eligible send that stops should be classified as cancelled")
    }

    runSuite("DictationAutoSendPolicy sends only after an eligible paste dispatch with text") {
        assertTrue(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                pasteOutcome: .pasted,
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
                pasteOutcome: .pasted,
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
                pasteOutcome: .copied(
                    "Paste dispatched without target confirmation",
                    reason: .pasteConfirmationUnavailable
                ),
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "an unattributed clipboard read must not authorize Auto Enter"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                pasteOutcome: .copied(
                    "Paste dispatched without a target read",
                    reason: .pasteConfirmationUnavailable
                ),
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "an unconfirmed dispatch without target-read evidence should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                pasteOutcome: .copied("Focus changed", reason: .focusChanged),
                text: "Send this",
                duration: TranscriptedConstants.dictationAutoEnterMinimumDuration,
                sourceBundleID: "com.example.Chat",
                allowedBundleIDs: ["com.example.Chat"]
            ),
            "a true copied-only fallback should not send"
        )

        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                pasteOutcome: .pasted,
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
                pasteOutcome: .pasted,
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
                pasteOutcome: .pasted,
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
                pasteOutcome: .pasted,
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

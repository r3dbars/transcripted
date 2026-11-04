import Foundation

func testStorageConfirmationPolicy() {
    runSuite("StorageConfirmationPolicy presents nothing when no prompt is pending") {
        assertNil(StorageConfirmationPolicy.activeSlot(StorageConfirmationStates()))
    }

    runSuite("StorageConfirmationPolicy presents each prompt through the one presenter") {
        assertEqual(
            StorageConfirmationPolicy.activeSlot(StorageConfirmationStates(pendingMeetingAudioWindow: .sevenDays)),
            .meetingAudio,
            "picking 7 days on Delete meeting audio after should present its prompt"
        )
        assertEqual(
            StorageConfirmationPolicy.activeSlot(StorageConfirmationStates(pendingDictationAudioWindow: .off)),
            .dictationAudio,
            "picking Don't keep on Keep dictation audio should present its prompt"
        )
        assertEqual(
            StorageConfirmationPolicy.activeSlot(StorageConfirmationStates(wantsFreeUpSpace: true)),
            .freeUpSpace
        )
        assertEqual(
            StorageConfirmationPolicy.activeSlot(StorageConfirmationStates(hasCaptureLibraryChoice: true)),
            .captureLibrary
        )
    }

    runSuite("StorageConfirmationPolicy keeps a second pending prompt for after the first") {
        // Dismissal clears only the active slot, so the next one still presents.
        var states = StorageConfirmationStates(
            hasCaptureLibraryChoice: true,
            pendingMeetingAudioWindow: .thirtyDays
        )
        assertEqual(StorageConfirmationPolicy.activeSlot(states), .captureLibrary)
        states.hasCaptureLibraryChoice = false
        assertEqual(StorageConfirmationPolicy.activeSlot(states), .meetingAudio)
        states.pendingMeetingAudioWindow = nil
        assertNil(StorageConfirmationPolicy.activeSlot(states))
    }

    runSuite("StorageConfirmationPolicy asks before a meeting window that can delete audio") {
        assertTrue(StorageConfirmationPolicy.meetingChoiceNeedsConfirmation(from: .never, to: .thirtyDays))
        assertTrue(StorageConfirmationPolicy.meetingChoiceNeedsConfirmation(from: .thirtyDays, to: .sevenDays))
        assertTrue(
            StorageConfirmationPolicy.meetingChoiceNeedsConfirmation(from: .sevenDays, to: .thirtyDays),
            "matches the old rule: every finite window asks"
        )
        assertFalse(StorageConfirmationPolicy.meetingChoiceNeedsConfirmation(from: .thirtyDays, to: .never))
        assertFalse(StorageConfirmationPolicy.meetingChoiceNeedsConfirmation(from: .thirtyDays, to: .thirtyDays))
    }

    runSuite("StorageConfirmationPolicy keeps the shipped prompt copy") {
        let off = StorageConfirmationStates(pendingDictationAudioWindow: .off)
        let week = StorageConfirmationStates(pendingDictationAudioWindow: .sevenDays)
        assertEqual(StorageConfirmationPolicy.title(for: .meetingAudio, states: StorageConfirmationStates()), "Delete old meeting audio?")
        assertEqual(StorageConfirmationPolicy.title(for: .dictationAudio, states: off), "Delete kept dictation audio?")
        assertEqual(StorageConfirmationPolicy.title(for: .dictationAudio, states: week), "Delete old dictation audio?")
        assertEqual(
            StorageConfirmationPolicy.meetingAudioMessage(for: .sevenDays),
            "Your transcripts and saved voices stay. Meeting audio older than 7 days is deleted now, and again automatically from then on."
        )
        assertEqual(
            StorageConfirmationPolicy.dictationAudioMessage(for: .off),
            "Your dictation text stays. All kept dictation audio is deleted now, and new dictations won't keep any."
        )
    }
}

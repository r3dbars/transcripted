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
            "Your transcripts stay. Meeting audio older than 7 days is deleted now, and again automatically from then on."
        )
        assertEqual(
            StorageConfirmationPolicy.dictationAudioMessage(for: .off),
            "Your dictation text stays. All kept dictation audio is deleted now, and new dictations won't keep any."
        )
    }

    // MARK: Meeting and dictation audio windows stay independent
    //
    // A user report on 1.1.75 said picking 30 days for meeting audio seemed to
    // set dictation audio too. These drive the page's pick → prompt →
    // Delete/Cancel flow through StorageRetentionPrompts and record which
    // setting each step would change.

    runSuite("A meeting audio choice never changes dictation audio, confirmed or cancelled") {
        for meetingCurrent in AudioRetentionWindow.allCases {
            for target in AudioRetentionWindow.allCases {
                for dictationCurrent in DictationAudioKeepWindow.allCases {
                    for confirms in [true, false] {
                        let label = "meeting \(meetingCurrent.rawValue) → \(target.rawValue), dictation \(dictationCurrent.rawValue), confirms \(confirms)"
                        var prompts = StorageRetentionPrompts()
                        var applied = RecordedRetentionApplies()
                        applied.record(prompts.pickMeeting(target, current: meetingCurrent))
                        assertNil(prompts.pendingDictation, "\(label): a meeting pick never leaves a dictation prompt")
                        if let effect = pressAlertButton(confirms: confirms, prompts: &prompts) {
                            applied.record(effect)
                        }

                        assertEqual(applied.dictation, [], "\(label): dictation audio must not change")
                        let asked = StorageConfirmationPolicy.meetingChoiceNeedsConfirmation(from: meetingCurrent, to: target)
                        let expected: [AudioRetentionWindow] = target == meetingCurrent || (asked && !confirms) ? [] : [target]
                        assertEqual(applied.meeting, expected, "\(label): only the picked meeting window applies, and only once")
                        assertEqual(prompts, StorageRetentionPrompts(), "\(label): nothing is left pending")
                    }
                }
            }
        }
    }

    runSuite("A dictation audio choice never changes meeting audio, confirmed or cancelled") {
        for dictationCurrent in DictationAudioKeepWindow.allCases {
            for target in DictationAudioKeepWindow.allCases {
                for meetingCurrent in AudioRetentionWindow.allCases {
                    for confirms in [true, false] {
                        let label = "dictation \(dictationCurrent.rawValue) → \(target.rawValue), meeting \(meetingCurrent.rawValue), confirms \(confirms)"
                        var prompts = StorageRetentionPrompts()
                        var applied = RecordedRetentionApplies()
                        applied.record(prompts.pickDictation(target, current: dictationCurrent))
                        assertNil(prompts.pendingMeeting, "\(label): a dictation pick never leaves a meeting prompt")
                        if let effect = pressAlertButton(confirms: confirms, prompts: &prompts) {
                            applied.record(effect)
                        }

                        assertEqual(applied.meeting, [], "\(label): meeting audio must not change")
                        let asked = dictationCurrent.deletesKeptAudio(switchingTo: target)
                        let expected: [DictationAudioKeepWindow] = target == dictationCurrent || (asked && !confirms) ? [] : [target]
                        assertEqual(applied.dictation, expected, "\(label): only the picked dictation window applies, and only once")
                        assertEqual(prompts, StorageRetentionPrompts(), "\(label): nothing is left pending")
                    }
                }
            }
        }
    }

    runSuite("Meeting audio 30 days with dictation at its 30-day default changes only meeting audio") {
        var prompts = StorageRetentionPrompts()
        var applied = RecordedRetentionApplies()
        applied.record(prompts.pickMeeting(.thirtyDays, current: .never))
        assertEqual(prompts.pendingMeeting, .thirtyDays, "picking 30 days asks first")
        assertEqual(applied.meeting, [], "nothing applies before the prompt is answered")
        assertEqual(
            StorageConfirmationPolicy.activeSlot(prompts.states()),
            .meetingAudio,
            "the meeting prompt is the one that shows"
        )
        if let effect = pressAlertButton(confirms: true, prompts: &prompts) {
            applied.record(effect)
        }
        assertEqual(applied.meeting, [.thirtyDays])
        assertEqual(applied.dictation, [], "dictation audio stays at its own 30-day default; nothing writes it")
    }

    runSuite("Cancel on an audio prompt applies nothing and clears only that prompt") {
        var prompts = StorageRetentionPrompts()
        assertEqual(prompts.pickMeeting(.sevenDays, current: .never), .none)
        assertEqual(pressAlertButton(confirms: false, prompts: &prompts), StorageRetentionEffect.none)
        assertEqual(prompts, StorageRetentionPrompts(), "Cancel on the meeting prompt leaves nothing pending")

        assertEqual(prompts.pickDictation(.off, current: .thirtyDays), .none)
        assertEqual(pressAlertButton(confirms: false, prompts: &prompts), StorageRetentionEffect.none)
        assertEqual(prompts, StorageRetentionPrompts(), "Cancel on the dictation prompt leaves nothing pending")
    }

    runSuite("A pending meeting prompt and a pending dictation prompt never apply each other") {
        var prompts = StorageRetentionPrompts(pendingMeeting: .sevenDays, pendingDictation: .off)
        assertEqual(StorageConfirmationPolicy.activeSlot(prompts.states()), .meetingAudio)
        assertEqual(prompts.confirmEffect(for: .meetingAudio), .applyMeeting(.sevenDays))
        assertEqual(prompts.confirmEffect(for: .dictationAudio), .applyDictation(.off))
        assertEqual(prompts.confirmEffect(for: .captureLibrary), .none, "other prompts carry no audio effect")
        assertEqual(prompts.confirmEffect(for: .freeUpSpace), .none, "other prompts carry no audio effect")

        // Delete Old Audio on the meeting prompt: meeting applies, dictation stays pending.
        assertEqual(pressAlertButton(confirms: true, prompts: &prompts), .applyMeeting(.sevenDays))
        assertNil(prompts.pendingMeeting)
        assertEqual(prompts.pendingDictation, .off, "the dictation prompt is still waiting for its own answer")
        assertEqual(StorageConfirmationPolicy.activeSlot(prompts.states()), .dictationAudio)
        assertEqual(pressAlertButton(confirms: true, prompts: &prompts), .applyDictation(.off))
        assertEqual(prompts, StorageRetentionPrompts())

        // Cancelling the meeting prompt keeps the dictation one.
        prompts = StorageRetentionPrompts(pendingMeeting: .thirtyDays, pendingDictation: .sevenDays)
        prompts.dismiss(.meetingAudio)
        assertEqual(prompts, StorageRetentionPrompts(pendingDictation: .sevenDays))

        // Dismissing a prompt that isn't an audio one clears neither window.
        prompts = StorageRetentionPrompts(pendingMeeting: .thirtyDays, pendingDictation: .sevenDays)
        prompts.dismiss(.captureLibrary)
        prompts.dismiss(.freeUpSpace)
        assertEqual(prompts, StorageRetentionPrompts(pendingMeeting: .thirtyDays, pendingDictation: .sevenDays))

        // A confirm for one prompt with only the other pending does nothing.
        prompts = StorageRetentionPrompts(pendingMeeting: .sevenDays)
        assertEqual(prompts.confirmEffect(for: .dictationAudio), .none)
        prompts = StorageRetentionPrompts(pendingDictation: .off)
        assertEqual(prompts.confirmEffect(for: .meetingAudio), .none)
    }

    runSuite("Audio prompts report their own windows to the presenter") {
        let prompts = StorageRetentionPrompts(pendingMeeting: .thirtyDays, pendingDictation: .sevenDays)
        assertEqual(
            prompts.states(hasCaptureLibraryChoice: true, wantsFreeUpSpace: true),
            StorageConfirmationStates(
                hasCaptureLibraryChoice: true,
                pendingMeetingAudioWindow: .thirtyDays,
                pendingDictationAudioWindow: .sevenDays,
                wantsFreeUpSpace: true
            )
        )
        assertEqual(prompts.states(), StorageConfirmationStates(
            pendingMeetingAudioWindow: .thirtyDays,
            pendingDictationAudioWindow: .sevenDays
        ))
    }

    runSuite("Choices that can't delete kept audio apply right away without a prompt") {
        var prompts = StorageRetentionPrompts()
        assertEqual(prompts.pickMeeting(.never, current: .thirtyDays), .applyMeeting(.never))
        assertEqual(prompts.pickDictation(.forever, current: .sevenDays), .applyDictation(.forever))
        assertEqual(prompts.pickDictation(.thirtyDays, current: .sevenDays), .applyDictation(.thirtyDays))
        assertEqual(prompts, StorageRetentionPrompts(), "no prompt is left pending")
        assertEqual(prompts.pickMeeting(.sevenDays, current: .sevenDays), .none, "re-picking the current window does nothing")
        assertEqual(prompts.pickDictation(.off, current: .off), .none, "re-picking the current window does nothing")
        assertEqual(prompts, StorageRetentionPrompts())
    }

    runSuite("An audio effect reaches only its own setting's callback") {
        var applied = RecordedRetentionApplies()
        applied.record(.applyMeeting(.sevenDays))
        applied.record(.applyDictation(.forever))
        applied.record(.none)
        assertEqual(applied.meeting, [.sevenDays])
        assertEqual(applied.dictation, [.forever])
    }
}

/// What the page's two apply callbacks would receive, routed through the same
/// `StorageRetentionEffect.perform` the page calls.
private struct RecordedRetentionApplies {
    var meeting: [AudioRetentionWindow] = []
    var dictation: [DictationAudioKeepWindow] = []

    mutating func record(_ effect: StorageRetentionEffect) {
        var meeting = self.meeting
        var dictation = self.dictation
        effect.perform(
            applyMeeting: { meeting.append($0) },
            applyDictation: { dictation.append($0) }
        )
        self.meeting = meeting
        self.dictation = dictation
    }
}

/// Plays the presenter: the showing prompt's destructive button carries the
/// effect built for it, then the alert dismisses that slot. Returns nil when
/// no prompt is showing, and `.none` for Cancel.
private func pressAlertButton(confirms: Bool, prompts: inout StorageRetentionPrompts) -> StorageRetentionEffect? {
    guard let slot = StorageConfirmationPolicy.activeSlot(prompts.states()) else { return nil }
    let effect = confirms ? prompts.confirmEffect(for: slot) : .none
    prompts.dismiss(slot)
    return effect
}

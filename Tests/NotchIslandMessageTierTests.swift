import Foundation

// The island's two tiers of message, its one "words didn't land" notice, its
// short wing words and its one countdown look, checked through what
// NotchIslandPresentation decides to draw.
func testNotchIslandMessageTier() {
    runSuite("A passing note stays in the wing and never opens the drop-down") {
        let texts = [
            DictationNoSpeechPresentationPolicy.message(trigger: "physical_key", shortcutMode: .pushToTalk),
            DictationNoSpeechPresentationPolicy.message(trigger: "physical_key", shortcutMode: .handsFree),
            DictationNoSpeechPresentationPolicy.message(trigger: "menu"),
        ]
        for text in texts {
            let message = NotchIslandDictationContent.Message(tone: .noSpeech, text: text, actionTitle: nil)
            let content = NotchIslandDictationContent(phase: .message(message))
            let layout = tierLayout(dictation: content)
            assertNil(layout.drop, "\(text) is news, not a question: no drop-down")
            assertFalse(layout.dropIsSticky, "nothing opens by itself")
            assertEqual(layout.left, [.symbol(.warning, .warning), .text("No speech", .title)], "two words in the wing")
            assertEqual(layout.right, [], "nothing to press on the right")
            assertNil(NotchIslandPresentation.stickyKey(dictation: content, meeting: nil, callPrompt: nil),
                      "nothing to close, so nothing to remember as closed")
            assertEqual(tierLayout(dictation: content, expanded: true).drop, .dictationNote(text),
                        "a hover shows the whole sentence")
            assertEqual(NotchIslandDropButtons.buttons(for: .dictationNote(text)), [], "with no button, not even Dismiss")
        }
    }

    runSuite("A too-short take and a take that didn't turn into words are passing notes too") {
        let short = DictationNoSpeechPresentationPolicy.message(trigger: "menu", reason: .recordingTooShort)
        let missed = DictationNoSpeechPresentationPolicy.message(trigger: "menu", reason: .audioNeedsRecovery)
        for (text, label) in [(short, "Too short"), (missed, "Didn't catch that")] {
            let message = NotchIslandDictationContent.Message(tone: .noSpeech, text: text, actionTitle: nil)
            let layout = tierLayout(dictation: NotchIslandDictationContent(phase: .message(message)))
            assertNil(layout.drop, "\(label) needs nothing from anyone")
            assertEqual(layout.left, [.symbol(.warning, .warning), .text(label, .title)])
        }
    }

    runSuite("A message that needs reading or a choice opens the drop-down") {
        let silent = DictationNoSpeechPresentationPolicy.message(trigger: "menu", silentMicName: "Desk Mic")
        let failed = DictationNoSpeechPresentationPolicy.message(trigger: "menu", reason: .modelFailure)
        let decisions: [(NotchIslandDictationContent.Message, String)] = [
            (.init(tone: .noSpeech, text: silent, actionTitle: nil), "Mic is silent"),
            (.init(tone: .noSpeech, text: failed, actionTitle: nil), "Model failed"),
            (.init(tone: .error, text: "Mic didn't start.", actionTitle: "Try again"), "Dictation"),
            (.init(tone: .error, text: "Couldn't save this dictation.", actionTitle: nil), "Dictation"),
            (.init(tone: .noSpeech, text: "No speech heard. Hold the dictation key while you talk.", actionTitle: "Transcribe"), "No speech"),
        ]
        for (message, label) in decisions {
            let layout = tierLayout(dictation: NotchIslandDictationContent(phase: .message(message)))
            assertEqual(layout.drop, .dictationMessage(message), "\(message.text) opens the drop-down")
            assertTrue(layout.dropIsSticky)
            assertEqual(layout.left.last, .text(label, .title), "the wing names it: \(label)")
        }
    }

    runSuite("A likely paste waiting on Return is a passing note that says so") {
        let message = NotchIslandDictationContent.Message(
            tone: .notice, text: DictationDeliveryPresentation.likelyPastedAutoSendNotice, actionTitle: nil
        )
        let layout = tierLayout(dictation: NotchIslandDictationContent(phase: .message(message)))
        assertNil(layout.drop, "the words went in; nothing to rescue")
        assertEqual(layout.left, [.symbol(.check, .accent), .text("Pasted", .title)], "a check, green: it just worked")
        assertEqual(layout.right, [.text("Press Return", .secondary)], "what's left to do, in the other wing")
        assertNil(tierLayout(dictation: NotchIslandDictationContent(phase: .message(message)), expanded: true).drop,
                  "the wings already say it all, so a hover adds nothing")

        let withRepair = NotchIslandDictationContent.Message(
            tone: .notice,
            text: "\(DictationDeliveryPresentation.likelyPastedAutoSendNotice) \(DictationDeliveryPresentation.pendingAudioNotice)",
            actionTitle: nil
        )
        assertEqual(tierLayout(dictation: NotchIslandDictationContent(phase: .message(withRepair))).drop,
                    .dictationMessage(withRepair), "with an audio problem added there is something to read, so it opens")
    }

    runSuite("Every notice about words that didn't land has one shape") {
        // Not pasted, maybe pasted, stale Accessibility, clipboard busy and
        // saved at the cap all carry the words and open the same drop-down.
        let family: [(text: String, action: String, hint: String?, tone: NotchIslandDictationContent.Message.Tone)] = [
            ("Not pasted", "Paste", nil, .notice),
            ("Maybe pasted", "Paste", "If the words aren\u{2019}t there, paste them again.", .notice),
            (StaleAccessibilityGrantCopy.islandTitle, StaleAccessibilityGrantCopy.islandActionTitle, StaleAccessibilityGrantCopy.islandHint, .notice),
            ("Not pasted", "Copy", "Your clipboard is too big to set aside.", .notice),
            ("Not pasted", "Paste", DictationSessionCapSavePolicy.islandHint(audioRetentionPending: false), .saved),
        ]
        for member in family {
            let message = NotchIslandDictationContent.Message(
                tone: member.tone, text: member.text, actionTitle: member.action,
                preview: "send the deck to Rosa by noon", dismissSeconds: 15, hint: member.hint
            )
            let layout = tierLayout(dictation: NotchIslandDictationContent(phase: .message(message)))
            assertEqual(layout.left, [.symbol(.clipboard, .neutral), .text(member.text, .title)],
                        "\(member.text) / \(member.action): the same clipboard and its own two words")
            assertEqual(layout.drop, .dictationMessage(message), "it opens with the words")
            let buttons = NotchIslandDropButtons.buttons(for: .dictationMessage(message))
            assertEqual(buttons.map(\.title), ["Dismiss", member.action], "Dismiss, then the one way to get the words in")
            assertEqual(buttons.map(\.role), [.standard, .primary])
            assertEqual(buttons.first?.countdown?.totalSeconds, 15, "the ring runs on Dismiss, the button that fires at zero")
            assertEqual(buttons.first?.countdown?.holdsWhileHovered, true, "and holds while someone reads")
            assertNil(buttons.last?.countdown, "only one ring")
        }
        assertEqual(StaleAccessibilityGrantCopy.islandActionTitle, "Open Settings", "the same words as the meeting's Settings button")
        assertTrue(DictationSessionCapSavePolicy.islandHint(audioRetentionPending: true)
                    .contains(DictationDeliveryPresentation.pendingAudioNotice), "a cap save with audio trouble still says so")
    }

    runSuite("Green is only for words that just went in") {
        let pasted = tierLayout(dictation: NotchIslandDictationContent(phase: .success(title: "Pasted")))
        assertEqual(pasted.left.first, .symbol(.check, .accent))
        for title in ["Audio saved", "Audio removed"] {
            let done = tierLayout(dictation: NotchIslandDictationContent(phase: .success(title: title)))
            assertEqual(done.left.first, .symbol(.check, .neutral), "\(title) is done, not live")
        }
        let copied = tierLayout(recentInsert: NotchIslandRecentInsert(title: "Copied", text: "Hi there"))
        assertEqual(copied.left.first, .symbol(.check, .neutral), "Copied is never green")
        let lingering = tierLayout(recentInsert: NotchIslandRecentInsert(title: "Pasted", text: "Hi there"))
        assertEqual(lingering.left.first, .symbol(.check, .accent))
    }

    runSuite("Meeting wing and drop-down say the same words") {
        var callAudioOn = NotchIslandMeetingContent(phase: .recording)
        callAudioOn.callAudioNote = .onForNextMeeting
        assertEqual(tierLayout(meeting: callAudioOn).right, [.text(NotchIslandMeetingCopy.callAudioNextMeeting, .secondary)])
        assertEqual(NotchIslandMeetingCopy.callAudioNextMeeting, "Call audio: next meeting")
        assertEqual(NotchIslandMeetingCopy.micMuted, "Mic muted", "one name for a muted mic, wing and drop-down")
        assertFalse(NotchIslandMeetingCopy.bothSides.lowercased().contains("call"), "a recording is a meeting, not a call")
        assertEqual(MeetingAutoRecordNoteCopy.detail, "", "Recording automatically says it all")
    }

    runSuite("A calendar call prompt doesn't repeat the meeting's title") {
        assertEqual(CapturePillController.promptDetail(title: "Weekly sync", detail: "Weekly sync - starts in 3 min"), "Starts in 3 min")
        assertEqual(CapturePillController.promptDetail(title: "Weekly sync", detail: "Weekly sync - starting now"), "Starting now")
        assertEqual(CapturePillController.promptDetail(title: "Zoom call detected", detail: "Or press ⌥M anytime."),
                    "Or press ⌥M anytime.", "an ad hoc call's detail is left alone")
        assertEqual(CapturePillController.promptDetail(title: "", detail: " - odd"), " - odd")
    }

    runSuite("A ring shows only what's left") {
        let half = NotchIslandCountdownRing(button: .primary, secondsLeft: 6, totalSeconds: 12, holdsWhileHovered: false)
        assertEqual(half.fraction, 0.5)
        assertEqual(NotchIslandCountdownRing(button: .primary, secondsLeft: 20, totalSeconds: 10, holdsWhileHovered: false).fraction, 1)
        assertEqual(NotchIslandCountdownRing(button: .primary, secondsLeft: -1, totalSeconds: 10, holdsWhileHovered: false).fraction, 0)
        assertEqual(NotchIslandCountdownRing(button: .primary, secondsLeft: 3, totalSeconds: 0, holdsWhileHovered: false).fraction, 1)
    }

    runSuite("A prompt whose countdown only moved is the same prompt") {
        var prompt = NotchIslandMeetingContent.Prompt(
            title: "No sound", detail: "Nothing heard for 3 minutes.", countdown: "Stops in 12s",
            primaryTitle: "Stop", secondaryTitle: "Dismiss", tertiaryTitle: nil
        )
        prompt.countdownRing = .init(button: .primary, secondsLeft: 12, totalSeconds: 30, holdsWhileHovered: false)
        var next = prompt
        next.countdown = "Stops in 11s"
        next.countdownRing?.secondsLeft = 11
        assertTrue(prompt.matchesIgnoringCountdown(next), "the buttons stay put under the pointer")
        var other = next
        other.title = "Call ended"
        assertFalse(prompt.matchesIgnoringCountdown(other), "a different warning is rebuilt")
    }
}

private func tierLayout(
    dictation: NotchIslandDictationContent? = nil,
    meeting: NotchIslandMeetingContent? = nil,
    recentInsert: NotchIslandRecentInsert? = nil,
    expanded: Bool = false
) -> NotchIslandLayout {
    NotchIslandPresentation.layout(
        dictation: dictation, meeting: meeting, callPrompt: nil,
        recentInsert: recentInsert, expanded: expanded
    )
}

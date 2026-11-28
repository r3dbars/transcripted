import Foundation

// Every island prompt against the button rule: the primary is the white
// pill (one at most), the rest are quiet, and red is only the confirm step
// of something destructive. "Dismiss" closes a notice everywhere but the call
// prompt, which says Skip.
func testNotchIslandDropButtons() {
    runSuite("The call prompt's Record is the white primary, and Skip carries the ring") {
        let buttons = NotchIslandDropButtons.buttons(for: .callPrompt(title: "Zoom call", detail: "Or press ⌥M anytime."), callSecondsLeft: 60)
        assertEqual(buttons.map(\.title), ["Skip", "Remind me", "Record"], "record, dismiss and remind all stay")
        assertEqual(buttons.map(\.role), [.standard, .standard, .primary], "Record is never red")
        assertEqual(buttons.map(\.action), [.callDismiss, .callRemind, .callRecord])
        assertEqual(buttons[0].countdown?.secondsLeft, 60, "the one countdown is the ring on Skip, what fires at zero")
        assertEqual(buttons[0].countdown?.holdsWhileHovered, true, "it holds while the pointer is on the island")
        assertNil(buttons[2].countdown)
    }

    runSuite("The quiet strip: a round Mute icon and the translucent Stop, both on the right") {
        let id = UUID()
        let buttons = NotchIslandDropButtons.buttons(for: .meetingControls(
            callAudioNote: nil, systemAudioUnverified: false, recordingID: id,
            micAction: .meetingMicMute(id)
        ))
        assertEqual(buttons.map(\.title), ["Mute", "Stop"])
        assertEqual(buttons.map(\.role), [.standard, .primary], "Stop saves the meeting, so it's safe, never red")
        assertEqual(buttons.map(\.look), [.icon, .quietPill], "no glaring white Stop block on the recording")
        assertEqual(buttons.map(\.placement), [.trailing, .trailing])
        assertEqual(buttons.map(\.symbol), ["mic", "stop.fill"])
        assertEqual(buttons.first?.toolTip, "Mute microphone", "an icon-only button says what it does on hover")
        assertEqual(buttons.last?.action, .meetingStop(id), "Stop names the recording it was drawn for")
        let unowned = NotchIslandDropButtons.buttons(for: .meetingControls(
            callAudioNote: nil, systemAudioUnverified: false
        ))
        assertEqual(unowned.map(\.title), [], "no recording to name, no Stop to press")
    }

    runSuite("Live meeting words: Copy and Mute icons on the left, Stop on the right") {
        let id = UUID()
        let buttons = NotchIslandDropButtons.buttons(for: .meetingControls(
            callAudioNote: nil, systemAudioUnverified: false, showsTranscript: true, recordingID: id,
            micAction: .meetingMicUnmute(id)
        ))
        assertEqual(buttons.map(\.action), [.meetingCopyTranscript, .meetingMicUnmute(id), .meetingStop(id)])
        assertEqual(buttons.map(\.placement), [.leading, .leading, .trailing])
        assertEqual(buttons.map(\.look), [.icon, .icon, .quietPill])
        assertEqual(buttons.map(\.toolTip), ["Copy live transcript", "Unmute microphone", nil])
        assertEqual(buttons[1].symbol, "mic.slash", "a muted mic shows the slashed icon")
        assertEqual(NotchIslandAction.meetingCopyTranscript.owner, .island, "the island copies the transcript itself")
        let off = NotchIslandDropButtons.buttons(for: .meetingControls(
            callAudioNote: nil, systemAudioUnverified: false, showsTranscript: false, recordingID: id
        ))
        assertFalse(off.contains { $0.action == .meetingCopyTranscript }, "nothing to copy while live words are off")
    }

    runSuite("The amber pill shows only when something is wrong") {
        let id = UUID()
        func warning(_ note: NotchIslandMeetingContent.CallAudioNote?, unverified: Bool = false,
                     mic: NotchIslandAction? = nil) -> NotchIslandMeetingWarning? {
            NotchIslandDropButtons.meetingWarning(for: .meetingControls(
                callAudioNote: note, systemAudioUnverified: unverified, recordingID: id, micAction: mic
            ))
        }
        assertNil(warning(nil, mic: .meetingMicMute(id)), "all well: no pill and no filler line")
        assertEqual(warning(.off), NotchIslandMeetingWarning(
            text: "Call audio is off", action: .meetingCallAudio, toolTip: "Turn on call audio"
        ), "call audio off: the pill turns it on")
        assertEqual(warning(.onForNextMeeting)?.text, "Call audio: next meeting")
        assertNil(warning(.onForNextMeeting)?.action)
        assertEqual(warning(nil, unverified: true)?.text, "Can't confirm call audio")
        assertEqual(warning(nil, mic: .meetingMicUnmute(id)), NotchIslandMeetingWarning(text: "Mic muted"))
        assertEqual(warning(.off, mic: .meetingMicUnmute(id))?.text, "Call audio is off", "call audio trouble wins, one pill at most")
        assertNil(NotchIslandDropButtons.meetingWarning(for: .meetingSaved(title: nil)), "only a recording has one")
    }

    runSuite("The recent take offers Paste again as the primary, on the right like every row") {
        let buttons = NotchIslandDropButtons.buttons(for: .justInserted(text: "Hi there", words: 2))
        assertEqual(buttons.map(\.title), ["Copy", "Paste again"])
        assertEqual(buttons.map(\.role), [.standard, .primary])
        assertEqual(buttons.map(\.placement), [.trailing, .trailing])
    }

    runSuite("The listening hover offers Cancel and Insert") {
        let buttons = NotchIslandDropButtons.buttons(for: .dictationTarget(appName: "Notes", showsPreview: false))
        assertEqual(buttons.map(\.title), ["Cancel", "Insert into Notes"])
        assertEqual(buttons.map(\.role), [.standard, .primary])
        assertEqual(buttons.last?.showsTargetAppIcon, true)
        assertEqual(NotchIslandDropButtons.buttons(for: .dictationTarget(appName: nil, showsPreview: false)).last?.title, "Insert now")
        assertEqual(NotchIslandDropButtons.buttons(for: .dictationTarget(appName: "Notes", showsPreview: true, isWriting: true)), [],
                    "nothing to press while the words are written")
    }

    runSuite("Notices close with Dismiss") {
        let error = NotchIslandDropButtons.buttons(for: .meetingError(title: "Couldn't save", message: "Disk full.", canOpen: true))
        assertEqual(error.map(\.title), ["Dismiss", "Open"])
        let denied = NotchIslandDropButtons.buttons(for: .meetingError(title: "x", message: "y", canOpen: false, grantsSystemAudio: true))
        assertEqual(denied.map(\.title), ["Dismiss", "Open Settings"])
        let micDenied = NotchIslandDropButtons.buttons(for: .meetingError(title: "x", message: "y", canOpen: false, grantsMicrophone: true))
        assertEqual(micDenied.map(\.title), ["Dismiss", "Open Settings"])
        assertEqual(NotchIslandDropButtons.buttons(for: .meetingCallAudioAsk).map(\.title), ["Dismiss", "Turn on"])
        let message = NotchIslandDictationContent.Message(tone: .error, text: "Mic didn't start.", actionTitle: "Try again")
        assertEqual(NotchIslandDropButtons.buttons(for: .dictationMessage(message)).map(\.title), ["Dismiss", "Try again"])
        assertEqual(NotchIslandDropButtons.buttons(for: .meetingSaved(title: nil)).map(\.title), ["Open"])
    }

    runSuite("The discard question: red Discard far left, Keep primary on the right with the ring") {
        let id = UUID()
        let prompt = MeetingDiscardConfirmCopy.prompt(recordingID: id, secondsLeft: 4)
        assertEqual(prompt.title, "Discard this recording?")
        let buttons = NotchIslandDropButtons.buttons(for: .meetingPrompt(prompt))
        assertEqual(buttons.map(\.title), ["Discard", "Keep"])
        assertEqual(buttons.map(\.role), [.destructive, .primary], "red only on the answer that deletes")
        assertEqual(buttons.map(\.placement), [.leading, .trailing],
                    "the red Discard sits away from where the first Discard was clicked")
        assertEqual(buttons.map(\.action), [.meetingPrompt(.tertiary, .discardConfirm(id)), .meetingPrompt(.primary, .discardConfirm(id))])
        assertNil(buttons[0].countdown, "time running out never discards")
        assertEqual(buttons[1].countdown?.button, .primary, "the ring is on Keep: keeping is what happens at zero")
        assertEqual(buttons[1].countdown?.secondsLeft, 4)
        assertEqual(buttons[1].countdown?.totalSeconds, MeetingDiscardConfirmPolicy.timeoutSeconds)
        assertEqual(buttons[1].countdown?.holdsWhileHovered, true)
    }

    runSuite("A prompt's ring lands on the button it names") {
        var prompt = NotchIslandMeetingContent.Prompt(
            title: "No sound", detail: "Nothing heard for 3 minutes.", countdown: "Stops in 12s",
            primaryTitle: "Stop", secondaryTitle: "Dismiss", tertiaryTitle: nil,
            identity: .inactivity(UUID(), .init(inactiveDuration: 180, countdownSeconds: 30))
        )
        prompt.countdownRing = .init(button: .primary, secondsLeft: 12, totalSeconds: 30, holdsWhileHovered: false)
        let buttons = NotchIslandDropButtons.buttons(for: .meetingPrompt(prompt))
        assertEqual(buttons.map(\.title), ["Dismiss", "Stop"])
        assertNil(buttons[0].countdown)
        assertEqual(buttons[1].countdown?.fraction, 0.4, "Stop fires at zero, so the ring is there, part run")
        assertEqual(buttons[1].countdown?.holdsWhileHovered, false, "that timer doesn't hold on hover, so neither does its ring")
    }

    runSuite("A button with a ring tells VoiceOver what happens at zero, and when") {
        let id = UUID()
        func words(_ drop: NotchIslandDrop, _ seconds: Int, callSecondsLeft: Int = 0) -> String? {
            guard let ringed = NotchIslandDropButtons.buttons(for: drop, callSecondsLeft: callSecondsLeft)
                .first(where: { $0.countdown != nil }) else { return nil }
            return NotchIslandDropButtons.countdownAccessibilityValue(for: ringed.action, secondsLeft: seconds)
        }
        var noSound = NotchIslandMeetingContent.Prompt(
            title: "No sound", detail: "", countdown: "", primaryTitle: "Stop", secondaryTitle: "Dismiss",
            tertiaryTitle: nil, identity: .inactivity(id, .init(inactiveDuration: 180, countdownSeconds: 30))
        )
        noSound.countdownRing = .init(button: .primary, secondsLeft: 12, totalSeconds: 30, holdsWhileHovered: false)
        assertEqual(words(.meetingPrompt(noSound), 12), "Stops in 12 seconds")
        assertEqual(words(.meetingPrompt(MeetingDiscardConfirmCopy.prompt(recordingID: id, secondsLeft: 4)), 4),
                    "Keeps recording in 4 seconds", "the discard question keeps the recording at zero")
        assertEqual(words(.callPrompt(title: "Call", detail: ""), 1, callSecondsLeft: 1), "Skips in 1 second")
        let notice = NotchIslandDrop.dictationMessage(.init(tone: .notice, text: "Not pasted", actionTitle: "Paste",
                                                            preview: "Some words", dismissSeconds: 15))
        assertEqual(words(notice, 15), "Closes in 15 seconds")
        assertEqual(NotchIslandDropButtons.countdownAccessibilityValue(for: .callDismiss, secondsLeft: -2),
                    "Skips in 0 seconds", "never a negative count")
    }

    runSuite("The 15-minute cap's saved words stay: no countdown, no ring, Paste still there") {
        let capSaved = NotchIslandDictationContent.Message.make(
            tone: .saved, text: "Not pasted", errorActionTitle: nil,
            notPasted: .init(text: "fifteen minutes of words", actionTitle: "Paste", hint: nil, dismissSeconds: nil)
        )
        assertNil(capSaved.dismissSeconds, "a notice without a countdown never closes by itself")
        let buttons = NotchIslandDropButtons.buttons(for: .dictationMessage(capSaved))
        assertEqual(buttons.map(\.title), ["Dismiss", "Paste"])
        assertTrue(buttons.allSatisfy { $0.countdown == nil }, "so Dismiss carries no ring")
    }

    runSuite("No drop-down has more than one primary or a red that isn't a confirm") {
        let id = UUID()
        let warning = NotchIslandMeetingContent.Prompt(
            title: "Call audio cut out", detail: "Your mic is still recording.", countdown: "",
            primaryTitle: "Stop", secondaryTitle: "Dismiss", tertiaryTitle: "Check access",
            identity: .systemAudio(id, .init(cause: .failure, phase: .degraded, isPromptDismissed: false))
        )
        let drops: [NotchIslandDrop] = [
            .dictationTarget(appName: "Notes", showsPreview: true),
            .dictationMessage(.init(tone: .notice, text: "Not pasted", actionTitle: "Paste", preview: "hi", dismissSeconds: 15)),
            .dictationMessage(.init(tone: .error, text: "Mic didn't start.", actionTitle: "Try again")),
            .justInserted(text: "Hi", words: 1),
            .meetingControls(callAudioNote: .off, systemAudioUnverified: false, recordingID: id,
                             micAction: .meetingMicMute(id)),
            .meetingControls(callAudioNote: nil, systemAudioUnverified: false, showsTranscript: true,
                             recordingID: id, micAction: .meetingMicMute(id)),
            .meetingPrompt(warning),
            .meetingPrompt(MeetingDiscardConfirmCopy.prompt(recordingID: id, secondsLeft: 10)),
            .meetingSaved(title: "Weekly sync"),
            .meetingError(title: "x", message: "y", canOpen: true),
            .callPrompt(title: "Zoom call", detail: "Or press ⌥M anytime."),
            .meetingCallAudioAsk,
        ]
        for drop in drops {
            let buttons = NotchIslandDropButtons.buttons(for: drop, callSecondsLeft: 30)
            assertTrue(buttons.filter { $0.role == .primary }.count <= 1, "\(drop): one primary at most")
            let red = buttons.filter { $0.role == .destructive }
            if case .meetingPrompt(let prompt) = drop, case .discardConfirm? = prompt.identity {
                assertEqual(red.count, 1, "the discard question's Discard is the one red button")
            } else {
                assertTrue(red.isEmpty, "\(drop): nothing else is red")
            }
            assertTrue(buttons.filter { $0.countdown != nil }.count <= 1, "\(drop): one ring at most")
        }
    }
}

import Foundation

func testNotchIslandPresentation() {
    runSuite("NotchIslandPresentation is empty with nothing going on") {
        let layout = notchLayout()
        assertTrue(layout.isEmpty, "an idle Mac shows no island")
        assertFalse(layout.showsEdgeProgress, "no progress edge while idle")
    }

    runSuite("NotchIslandPresentation shows a listening dictation on both wings") {
        let layout = notchLayout(dictation: listening())
        assertEqual(layout.left, [.symbol(.mic, .accent), .text("Listening", .title)])
        assertEqual(layout.right, [.dictationBars(count: 9), .live(.dictationTimer, .secondary)])
        assertNil(layout.drop, "listening does not open the drop-down by itself")

        let hovered = notchLayout(dictation: listening(), expanded: true)
        assertEqual(
            hovered.drop,
            .dictationTarget(appName: "Notes", showsPreview: false),
            "with no live words, a hover offers Cancel and Insert into the app"
        )
        assertFalse(hovered.dropIsSticky, "a hover drop-down closes when the pointer leaves")
    }

    runSuite("NotchIslandPresentation shows the live words while a dictation streams") {
        var content = listening()
        content.showsLivePreview = true
        assertEqual(
            notchLayout(dictation: content, expanded: true).drop,
            .dictationTarget(appName: "Notes", showsPreview: true),
            "hovering a streaming take shows the words over Cancel and Insert"
        )
        content.phase = .writing
        assertEqual(
            notchLayout(dictation: content, expanded: true).drop,
            .dictationTarget(appName: "Notes", showsPreview: true, isWriting: true),
            "the words stay, without buttons, while the take is written"
        )
        content.phase = .success(title: "Pasted")
        assertEqual(
            notchLayout(dictation: content, expanded: true).drop,
            .dictationTarget(appName: "Notes", showsPreview: true, isWriting: true),
            "they stay through Pasted, where they turn into the written text"
        )
        content.showsLivePreview = false
        assertNil(notchLayout(dictation: content, expanded: true).drop, "a take with no live words has nothing to show once released")
    }

    runSuite("NotchIslandPresentation keeps the key-down beat to a dot") {
        let layout = notchLayout(dictation: NotchIslandDictationContent(phase: .starting))
        assertEqual(layout.left, [.accentDot])
        assertEqual(layout.right, [])
    }

    runSuite("NotchIslandPresentation counts down the dictation cap on the right wing") {
        var content = listening()
        content.notice = DictationSessionCapWarningPolicy.notice(remainingSeconds: 28, shortcutMode: .pushToTalk)
        let layout = notchLayout(dictation: content)
        assertEqual(layout.left, [.symbol(.mic, .accent), .text("Listening", .title)])
        assertEqual(layout.right, [.dictationBars(count: 9), .text("28s left", .warning)])
    }

    runSuite("NotchIslandPresentation shows the Esc confirm prompt as a warning") {
        var content = listening()
        content.notice = "Press Esc again to discard"
        let layout = notchLayout(dictation: content)
        assertEqual(layout.left, [.symbol(.warning, .warning), .text("Press Esc again to discard", .warning)])
        assertEqual(layout.right, [.dictationBars(count: 9)])
    }

    runSuite("NotchIslandPresentation shows loading with a ring only for a real number") {
        let waiting = notchLayout(dictation: NotchIslandDictationContent(
            phase: .loading(title: "Warming up", detail: "Starts when ready.", progress: nil)
        ))
        assertEqual(waiting.left, [.spinner, .text("Warming up", .title)])
        assertEqual(waiting.right, [])

        let downloading = notchLayout(dictation: NotchIslandDictationContent(
            phase: .loading(title: "Downloading", detail: "Once only.", progress: 0.42)
        ))
        assertEqual(downloading.left, [.loadingRing, .text("Downloading", .title)])
        assertEqual(downloading.right, [.live(.loadingPercent, .secondary)])

        let hovered = notchLayout(
            dictation: NotchIslandDictationContent(phase: .loading(title: "Warming up", detail: "Starts when ready.", progress: nil)),
            expanded: true
        )
        assertEqual(hovered.drop, .dictationLoading(title: "Warming up", detail: "Starts when ready."))
    }

    runSuite("NotchIslandPresentation shows writing and the landed text") {
        let writing = notchLayout(dictation: NotchIslandDictationContent(phase: .writing))
        assertEqual(writing.left, [.dots, .text("Writing", .title)])
        assertEqual(writing.right, [.shimmer])
        assertNil(notchLayout(dictation: NotchIslandDictationContent(phase: .writing), expanded: true).drop,
                  "nothing to offer while the words are written")

        let pasted = notchLayout(dictation: NotchIslandDictationContent(phase: .success(title: "Pasted")))
        assertEqual(pasted.left, [.symbol(.check, .accent), .text("Pasted", .title)])
    }

    runSuite("NotchIslandPresentation opens a dictation message by itself until it is closed") {
        let message = NotchIslandDictationContent.Message(tone: .error, text: "Mic didn't start.", actionTitle: "Try Again")
        let content = NotchIslandDictationContent(phase: .message(message))
        let layout = notchLayout(dictation: content)
        assertEqual(layout.left, [.symbol(.warning, .warning), .text("Dictation", .title)])
        assertEqual(layout.drop, .dictationMessage(message))
        assertTrue(layout.dropIsSticky, "a message opens the drop-down by itself")

        let key = NotchIslandPresentation.stickyKey(dictation: content, meeting: nil, callPrompt: nil)
        assertEqual(key, "dictation-message:Mic didn't start.")
        let closed = notchLayout(dictation: content, collapsedStickyKey: key)
        assertNil(closed.drop, "a closed message stays closed")
        let reopened = notchLayout(dictation: content, expanded: true, collapsedStickyKey: key)
        assertEqual(reopened.drop, .dictationMessage(message), "a hover or click reopens it")
    }

    runSuite("NotchIslandPresentation labels each kind of dictation message") {
        let cases: [(NotchIslandDictationContent.Message.Tone, String, String, NotchIslandSymbol)] = [
            (.error, "Something broke", "Dictation", .warning),
            (.noSpeech, "No speech heard", "No speech", .warning),
            (.notice, "Pasted, press Return to send", "Pasted", .clipboard),
            (.notice, "Copied. Press ⌘V to paste.", "Copied", .clipboard),
            (.saved, "Saved to your dictations", "Saved", .saved),
        ]
        for (tone, text, label, symbol) in cases {
            let message = NotchIslandDictationContent.Message(tone: tone, text: text, actionTitle: nil)
            assertEqual(NotchIslandPresentation.messageLabel(message), label, "\(text) should read \(label)")
            let layout = notchLayout(dictation: NotchIslandDictationContent(phase: .message(message)))
            assertEqual(layout.left.first, .symbol(symbol, tone == .error || tone == .noSpeech ? .warning : .accent))
        }
    }

    runSuite("NotchIslandPresentation names an unconfirmed paste as maybe pasted, not missing") {
        let message = NotchIslandDictationContent.Message(
            tone: .notice,
            text: "Maybe pasted",
            actionTitle: "Paste",
            preview: "send me the notes",
            dismissSeconds: 15
        )
        assertEqual(NotchIslandPresentation.messageLabel(message), "Maybe pasted",
                    "a paste that likely landed shouldn't claim it didn't, or the Paste button doubles it")
    }

    runSuite("NotchIslandPresentation shows the words of a dictation that didn't paste") {
        let message = NotchIslandDictationContent.Message(
            tone: .notice,
            text: "Not pasted",
            actionTitle: "Paste",
            preview: "send me the notes",
            dismissSeconds: 15
        )
        assertEqual(NotchIslandPresentation.messageLabel(message), "Not pasted")
        let content = NotchIslandDictationContent(phase: .message(message))
        let layout = notchLayout(dictation: content)
        assertEqual(layout.left, [.symbol(.clipboard, .accent), .text("Not pasted", .title)])
        assertEqual(layout.drop, .dictationMessage(message), "the words and the Paste button open by themselves")

        var next = message
        next.preview = "a different take"
        assertTrue(
            NotchIslandPresentation.stickyKey(dictation: content, meeting: nil, callPrompt: nil)
                != NotchIslandPresentation.stickyKey(dictation: NotchIslandDictationContent(phase: .message(next)), meeting: nil, callPrompt: nil),
            "closing one missed paste doesn't keep the next one closed"
        )
    }

    runSuite("A clipboard too busy to paste through offers to copy the words") {
        let message = NotchIslandDictationContent.Message(
            tone: .notice,
            text: "Not pasted",
            actionTitle: "Copy",
            preview: "send me the notes",
            dismissSeconds: 15,
            hint: "Your clipboard holds something too big to set aside."
        )
        assertEqual(NotchIslandPresentation.messageLabel(message), "Not pasted")
        let layout = notchLayout(dictation: NotchIslandDictationContent(phase: .message(message)))
        assertEqual(layout.drop, .dictationMessage(message), "the words, the reason and Copy open by themselves")
    }

    runSuite("NotchIslandPresentation splits a dictation over a live meeting") {
        let layout = notchLayout(dictation: listening(), meeting: recording())
        assertEqual(layout.left, [.recordingDot, .live(.meetingTimer, .title)], "the meeting keeps the left wing")
        assertEqual(layout.right, [.symbol(.mic, .accent), .dictationBars(count: 6)], "dictation takes the right")
    }

    runSuite("NotchIslandPresentation keeps a meeting's hover during a dictation in it") {
        var meeting = recording()
        meeting.showsLiveTranscript = true
        var content = listening()
        content.showsLivePreview = true
        assertEqual(
            notchLayout(dictation: content, meeting: meeting, expanded: true).drop,
            .meetingControls(callAudioNote: nil, systemAudioUnverified: false, showsTranscript: true),
            "hovering during a meeting shows the meeting, not the dictation's words"
        )
    }

    runSuite("NotchIslandPresentation shows the call prompt with one Record") {
        let prompt = NotchIslandCallPromptContent(title: "Zoom call", detail: "Record this meeting?", secondsLeft: 30)
        let open = notchLayout(callPrompt: prompt)
        assertEqual(open.left, [.symbol(.video, .accent), .text("Call", .title)])
        assertEqual(open.drop, .callPrompt(title: "Zoom call", detail: "Record this meeting?"))
        assertTrue(open.dropIsSticky)
        assertEqual(open.right, [.live(.callSeconds, .secondary)], "the drop-down has the Record button, so the wing just counts")

        let key = NotchIslandPresentation.stickyKey(dictation: nil, meeting: nil, callPrompt: prompt)
        let closed = notchLayout(callPrompt: prompt, collapsedStickyKey: key)
        assertNil(closed.drop)
        assertEqual(closed.right, [.chip("Record", .destructive, .callRecord)], "closed, the wing offers Record")
    }

    runSuite("NotchIslandPresentation holds a prompt while a dictation runs") {
        let prompt = NotchIslandCallPromptContent(title: "Zoom call", detail: "Record this meeting?", secondsLeft: 30)
        let layout = notchLayout(dictation: listening(), callPrompt: prompt)
        assertNil(layout.drop, "the call prompt waits until the words land")
        assertEqual(layout.left, [.symbol(.mic, .accent), .text("Listening", .title)])
    }

    runSuite("NotchIslandPresentation shows a recording meeting and its notes") {
        let plain = notchLayout(meeting: recording())
        assertEqual(plain.left, [.recordingDot, .live(.meetingTimer, .title)])
        assertEqual(plain.right, [.meetingMeters])
        assertEqual(
            notchLayout(meeting: recording(), expanded: true).drop,
            .meetingControls(callAudioNote: nil, systemAudioUnverified: false)
        )

        var transcribing = recording()
        transcribing.showsLiveTranscript = true
        assertEqual(
            notchLayout(meeting: transcribing, expanded: true).drop,
            .meetingControls(callAudioNote: nil, systemAudioUnverified: false, showsTranscript: true),
            "with Live transcript on, hovering shows the conversation"
        )
        assertEqual(notchLayout(meeting: transcribing).right, [.meetingMeters], "the collapsed island doesn't change")
        assertEqual(NotchIslandAction.meetingCopyTranscript.owner, .island, "the island copies the transcript itself")

        let meetingDrop = NotchIslandDrop.meetingControls(callAudioNote: nil, systemAudioUnverified: false, showsTranscript: true)
        assertEqual(
            notchLayout(dictation: listening(), meeting: transcribing, expanded: true).drop,
            meetingDrop,
            "a dictation inside the meeting doesn't take the meeting's hover"
        )
        assertEqual(
            notchLayout(dictation: NotchIslandDictationContent(phase: .writing), meeting: transcribing, expanded: true).drop,
            meetingDrop,
            "once the key is up, hovering shows the meeting again"
        )
        assertEqual(
            notchLayout(meeting: transcribing, recentInsert: NotchIslandRecentInsert(title: "Pasted", text: "Hi there"), expanded: true).drop,
            meetingDrop,
            "the dictation that just landed doesn't take the meeting's hover"
        )
        assertEqual(
            notchLayout(recentInsert: NotchIslandRecentInsert(title: "Pasted", text: "Hi there"), expanded: true).drop,
            .justInserted(text: "Hi there", words: 2),
            "with no meeting, the hover still offers Copy and Paste again"
        )

        var micOnly = recording()
        micOnly.callAudioNote = .off
        assertEqual(notchLayout(meeting: micOnly).right, [.chip("Mic only", .warning, .meetingCallAudio)])
        assertEqual(
            notchLayout(meeting: micOnly, expanded: true).right,
            [.text("Mic only", .warning)],
            "with the drop-down open the chip becomes a label"
        )

        var callAudioOn = recording()
        callAudioOn.callAudioNote = .onForNextMeeting
        assertEqual(notchLayout(meeting: callAudioOn).right, [.text("Call audio next time", .secondary)])

        var unverified = recording()
        unverified.systemAudioUnverified = true
        unverified.callAudioNote = .off
        assertEqual(notchLayout(meeting: unverified).right, [.text("Can't confirm call", .warning)])
    }

    runSuite("NotchIslandPresentation opens meeting warnings by itself") {
        var meeting = recording()
        meeting.prompt = NotchIslandMeetingContent.Prompt(
            title: "No audio detected",
            detail: "No mic or system audio for 5 minutes.",
            countdown: "Ends in 30s",
            primaryTitle: "End & Transcribe",
            secondaryTitle: "Keep Recording",
            tertiaryTitle: nil
        )
        let open = notchLayout(meeting: meeting)
        assertEqual(open.drop, .meetingPrompt(meeting.prompt!))
        assertTrue(open.dropIsSticky)

        let key = NotchIslandPresentation.stickyKey(dictation: nil, meeting: meeting, callPrompt: nil)
        let closed = notchLayout(meeting: meeting, collapsedStickyKey: key)
        assertNil(closed.drop)
        assertEqual(closed.right, [.symbol(.warning, .warning), .meetingMeters], "a closed warning leaves a mark on the wing")

        var nextSecond = meeting
        nextSecond.prompt?.countdown = "Ends in 29s"
        assertEqual(
            NotchIslandPresentation.stickyKey(dictation: nil, meeting: nextSecond, callPrompt: nil),
            key,
            "a ticking countdown is the same warning, so a closed one stays closed"
        )
    }

    runSuite("NotchIslandPresentation shows the missed-call nudge with nothing recording") {
        let meeting = NotchIslandMeetingContent(
            phase: .none,
            prompt: NotchIslandMeetingContent.Prompt(
                title: "That Zoom call wasn't recorded",
                detail: "About 20 minutes.",
                countdown: "",
                primaryTitle: "Got It",
                secondaryTitle: "Don't show again",
                tertiaryTitle: nil
            )
        )
        let layout = notchLayout(meeting: meeting)
        assertEqual(layout.left, [.symbol(.video, .accent), .text("Missed call", .title)])
        assertEqual(layout.drop, .meetingPrompt(meeting.prompt!))
    }

    runSuite("NotchIslandPresentation finishes a meeting") {
        let preparing = notchLayout(meeting: NotchIslandMeetingContent(phase: .preparing(title: "Starting meeting…", detail: "Checking permissions and audio")))
        assertEqual(preparing.left, [.spinner, .text("Starting meeting…", .title)])

        let transcribing = notchLayout(meeting: NotchIslandMeetingContent(phase: .transcribing(progress: 0.42, detail: "42%")))
        assertEqual(transcribing.left, [.transcriptionRing, .text("Transcribing", .title)])
        assertEqual(transcribing.right, [.text("42%", .secondary)])
        assertTrue(transcribing.showsEdgeProgress, "progress runs along the lower edge")

        let saved = notchLayout(meeting: NotchIslandMeetingContent(phase: .saved(title: "Weekly sync")))
        assertEqual(saved.left, [.symbol(.check, .accent), .text("Saved", .title)])
        assertEqual(saved.right, [.chip("Open", .plain, .meetingOpen)])
        let savedOpen = notchLayout(meeting: NotchIslandMeetingContent(phase: .saved(title: "Weekly sync")), expanded: true)
        assertEqual(savedOpen.drop, .meetingSaved(title: "Weekly sync"))
        assertEqual(savedOpen.right, [.text("Open", .secondary)])

        let failed = NotchIslandMeetingContent(phase: .error(title: "Microphone didn't start", message: "Check your input device.", canOpen: false))
        let error = notchLayout(meeting: failed)
        assertEqual(error.left, [.symbol(.warning, .warning), .text("Meeting failed", .title)])
        assertEqual(error.drop, .meetingError(title: "Microphone didn't start", message: "Check your input device.", canOpen: false))

        let denied = NotchIslandMeetingContent(phase: .error(
            title: "Turn on System Audio Recording",
            message: "Turn on System Audio Recording in System Settings, then retry the meeting.",
            canOpen: true,
            grantsSystemAudio: true
        ))
        let deniedLayout = notchLayout(meeting: denied)
        assertEqual(
            deniedLayout.drop,
            .meetingError(
                title: "Turn on System Audio Recording",
                message: "Turn on System Audio Recording in System Settings, then retry the meeting.",
                canOpen: true,
                grantsSystemAudio: true
            ),
            "a confirmed System Audio denial carries its Settings action into the drop-down"
        )
        assertTrue(error.dropIsSticky)
    }

    runSuite("NotchIslandPresentation lingers on the dictation that just landed") {
        let insert = NotchIslandRecentInsert(title: "Pasted", text: "Ship the notch island today")
        let layout = notchLayout(recentInsert: insert)
        assertEqual(layout.left, [.symbol(.check, .accent), .text("Pasted", .title)])
        assertEqual(layout.right, [.text("5 words", .secondary)])
        assertEqual(
            notchLayout(recentInsert: insert, expanded: true).drop,
            .justInserted(text: "Ship the notch island today", words: 5)
        )
        assertEqual(notchLayout(recentInsert: NotchIslandRecentInsert(title: "Pasted", text: "Hi")).right, [.text("1 word", .secondary)])
        assertEqual(notchLayout(recentInsert: NotchIslandRecentInsert(title: "Pasted", text: nil)).right, [])
    }

    runSuite("NotchIslandPresentation never offers a button twice") {
        let prompt = NotchIslandCallPromptContent(title: "Zoom call", detail: "Record?", secondsLeft: 12)
        var micOnly = recording()
        micOnly.callAudioNote = .off
        let layouts = [
            notchLayout(callPrompt: prompt),
            notchLayout(meeting: micOnly, expanded: true),
            notchLayout(meeting: NotchIslandMeetingContent(phase: .saved(title: nil)), expanded: true),
        ]
        for layout in layouts {
            assertTrue(layout.drop != nil)
            let chips = (layout.left + layout.right).filter {
                if case .chip = $0 { return true }
                return false
            }
            assertTrue(chips.isEmpty, "with the drop-down open the wings only report status")
        }
    }

    runSuite("NotchIslandPresentation formats timers and counts words") {
        assertEqual(NotchIslandPresentation.timerText(0), "0:00")
        assertEqual(NotchIslandPresentation.timerText(65), "1:05")
        assertEqual(NotchIslandPresentation.timerText(3725), "1:02:05")
        assertEqual(NotchIslandPresentation.timerText(-3), "0:00")
        assertEqual(NotchIslandPresentation.wordCount("  two\nwords  "), 2)
        assertEqual(NotchIslandPresentation.wordCount(nil), 0)
    }

    runSuite("NotchIslandAction routes each tap to its owner") {
        assertEqual(NotchIslandAction.dictationStop.owner, .dictation)
        assertEqual(NotchIslandAction.dictationDismissMessage.owner, .dictation)
        assertEqual(NotchIslandAction.copyLastDictation.owner, .island)
        assertEqual(NotchIslandAction.pasteLastDictation.owner, .island)
        assertEqual(NotchIslandAction.meetingCallAudio.owner, .meeting)
        assertEqual(NotchIslandAction.meetingOpen.owner, .meeting)
        assertEqual(NotchIslandAction.callRecord.owner, .callPrompt)
        assertEqual(NotchIslandAction.callRemind.owner, .callPrompt)
    }

    runSuite("The call prompt is off screen while a dictation has the island, and back once it lands") {
        let prompt = NotchIslandCallPromptContent(title: "Zoom call", detail: "Record this meeting?", secondsLeft: 30)
        let message = NotchIslandDictationContent.Message(tone: .error, text: "Mic didn't start.", actionTitle: nil)
        let covering: [NotchIslandDictationContent] = [
            NotchIslandDictationContent(phase: .starting),
            listening(),
            NotchIslandDictationContent(phase: .message(message)),
        ]
        for dictation in covering {
            assertFalse(
                NotchIslandPresentation.callPromptIsOnScreen(dictation: dictation, callPrompt: prompt),
                "a prompt behind \(dictation.phase) can't be seen"
            )
            let layout = notchLayout(dictation: dictation, callPrompt: prompt)
            assertFalse(layout.drop == .callPrompt(title: prompt.title, detail: prompt.detail), "and isn't drawn")
            assertFalse(layout.left.contains(.text("Call", .title)), "not even in the wings")
        }
        assertTrue(NotchIslandPresentation.callPromptIsOnScreen(dictation: nil, callPrompt: prompt))
        assertEqual(
            notchLayout(callPrompt: prompt).drop,
            .callPrompt(title: prompt.title, detail: prompt.detail),
            "on screen means it is drawn"
        )
        assertFalse(NotchIslandPresentation.callPromptIsOnScreen(dictation: nil, callPrompt: nil), "no prompt, nothing on screen")
    }

    runSuite("The island keeps the keyboard only while it is asking for names on screen") {
        let naming = NotchIslandSpeakerReviewContent(reviewID: UUID(), meetingTitle: "Standup", stage: .naming)
        let done = NotchIslandSpeakerReviewContent(reviewID: UUID(), meetingTitle: "Standup", stage: .done(leftForLater: 0))
        assertTrue(NotchIslandPresentation.speakerReviewKeepsKeyboard(naming, onScreen: true), "typing a name keeps it")
        assertFalse(
            NotchIslandPresentation.speakerReviewKeepsKeyboard(naming, onScreen: false),
            "a dictation or the next meeting covering the review gives it back"
        )
        assertFalse(NotchIslandPresentation.speakerReviewKeepsKeyboard(done, onScreen: true), "Everyone's named gives it back")
        assertFalse(NotchIslandPresentation.speakerReviewKeepsKeyboard(nil, onScreen: false), "a finished or replaced review gives it back")
    }

    runSuite("A meeting tick that only moves the clock skips the full island rebuild") {
        let base = recording()
        var ticked = base
        ticked.duration += 1
        assertEqual(NotchIslandPresentation.meetingUpdate(from: base, to: base), .unchanged, "same snapshot, nothing to do")
        assertEqual(NotchIslandPresentation.meetingUpdate(from: base, to: ticked), .durationOnly, "a clock tick only refreshes the timer")
        assertEqual(NotchIslandPresentation.meetingUpdate(from: nil, to: nil), .unchanged, "no meeting before or after")
    }

    runSuite("Any meeting change besides the clock rebuilds the island") {
        let base = recording()
        var phase = base
        phase.phase = .transcribing(progress: 0.5, detail: "Transcribing")
        var prompt = base
        prompt.prompt = NotchIslandMeetingContent.Prompt(
            title: "Meeting detected",
            detail: "Zoom",
            countdown: "10",
            primaryTitle: "Record",
            secondaryTitle: "Not now",
            tertiaryTitle: nil
        )
        var note = base
        note.callAudioNote = .off
        var phaseAndClock = phase
        phaseAndClock.duration += 1
        assertEqual(NotchIslandPresentation.meetingUpdate(from: base, to: phase), .full, "a new phase")
        assertEqual(NotchIslandPresentation.meetingUpdate(from: base, to: prompt), .full, "a new prompt")
        assertEqual(NotchIslandPresentation.meetingUpdate(from: base, to: note), .full, "a new call-audio note")
        assertEqual(NotchIslandPresentation.meetingUpdate(from: base, to: phaseAndClock), .full, "a new phase with a tick")
        assertEqual(NotchIslandPresentation.meetingUpdate(from: base, to: nil), .full, "the meeting went away")
        assertEqual(NotchIslandPresentation.meetingUpdate(from: nil, to: base), .full, "a meeting arrived")
    }

    runSuite("Only the spoken dictation's hover drop-down is kept between hovers") {
        assertTrue(NotchIslandDrop.dictationTarget(appName: "Notes", showsPreview: true).staysBuiltBetweenHovers,
                   "the streaming take's drop-down stays built")
        assertTrue(NotchIslandDrop.dictationTarget(appName: nil, showsPreview: false).staysBuiltBetweenHovers,
                   "so does a take with no app and no live words")
        assertTrue(NotchIslandDrop.dictationTarget(appName: "Notes", showsPreview: false, isWriting: false).staysBuiltBetweenHovers,
                   "isWriting: false spelled out")
        assertFalse(NotchIslandDrop.dictationTarget(appName: "Notes", showsPreview: true, isWriting: true).staysBuiltBetweenHovers,
                    "once the take is being written it isn't kept")
        assertFalse(NotchIslandDrop.dictationTarget(appName: nil, showsPreview: false, isWriting: true).staysBuiltBetweenHovers,
                    "being written, with nothing else either")

        let prompt = NotchIslandMeetingContent.Prompt(
            title: "Meeting detected",
            detail: "Zoom",
            countdown: "10",
            primaryTitle: "Record",
            secondaryTitle: "Not now",
            tertiaryTitle: nil
        )
        let others: [(String, NotchIslandDrop)] = [
            ("dictationLoading", .dictationLoading(title: "Warming up", detail: "Starts when ready.")),
            ("dictationMessage", .dictationMessage(NotchIslandDictationContent.Message(tone: .error, text: "Mic didn't start.", actionTitle: "Try Again"))),
            ("dictationMessage notice", .dictationMessage(NotchIslandDictationContent.Message(tone: .notice, text: "Copied", actionTitle: nil))),
            ("justInserted", .justInserted(text: "Hello there", words: 2)),
            ("meetingPreparing", .meetingPreparing(title: "Starting", detail: "Getting the mic ready.")),
            ("meetingControls", .meetingControls(callAudioNote: nil, systemAudioUnverified: false)),
            ("meetingControls with note", .meetingControls(callAudioNote: .off, systemAudioUnverified: true, showsTranscript: true)),
            ("meetingPrompt", .meetingPrompt(prompt)),
            ("meetingSaved", .meetingSaved(title: "Standup")),
            ("meetingSaved untitled", .meetingSaved(title: nil)),
            ("meetingError", .meetingError(title: "Couldn't save", message: "Disk full.", canOpen: true)),
            ("meetingError system audio", .meetingError(title: "No call audio", message: "Allow it.", canOpen: false, grantsSystemAudio: true)),
            ("callPrompt", .callPrompt(title: "Zoom call", detail: "Record this meeting?")),
            ("speakerReview", .speakerReview(NotchIslandSpeakerReviewContent(reviewID: UUID(), meetingTitle: "Standup", stage: .naming))),
            ("speakerReview done", .speakerReview(NotchIslandSpeakerReviewContent(reviewID: UUID(), meetingTitle: nil, stage: .done(leftForLater: 2)))),
            ("meetingCallAudioAsk", .meetingCallAudioAsk),
        ]
        for (label, drop) in others {
            assertFalse(drop.staysBuiltBetweenHovers, "\(label) is rebuilt like any other drop-down")
        }

        // Through the layout: hovering a listening take gives the kept drop-down,
        // hovering the same take while it's written does not.
        var content = listening()
        content.showsLivePreview = true
        assertEqual(notchLayout(dictation: content, expanded: true).drop?.staysBuiltBetweenHovers, true,
                    "a hovered take that's still being spoken is kept")
        content.phase = .writing
        assertEqual(notchLayout(dictation: content, expanded: true).drop?.staysBuiltBetweenHovers, false,
                    "a hovered take that's being written is not")
    }
}

private func notchLayout(
    dictation: NotchIslandDictationContent? = nil,
    meeting: NotchIslandMeetingContent? = nil,
    callPrompt: NotchIslandCallPromptContent? = nil,
    recentInsert: NotchIslandRecentInsert? = nil,
    expanded: Bool = false,
    collapsedStickyKey: String? = nil
) -> NotchIslandLayout {
    NotchIslandPresentation.layout(
        dictation: dictation,
        meeting: meeting,
        callPrompt: callPrompt,
        recentInsert: recentInsert,
        expanded: expanded,
        collapsedStickyKey: collapsedStickyKey
    )
}

private func listening() -> NotchIslandDictationContent {
    NotchIslandDictationContent(
        phase: .listening,
        targetAppName: "Notes"
    )
}

private func recording() -> NotchIslandMeetingContent {
    NotchIslandMeetingContent(phase: .recording, duration: 754)
}

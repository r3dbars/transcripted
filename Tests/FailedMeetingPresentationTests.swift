import Foundation

func testFailedMeetingPresentation() {
    runSuite("FailedMeetingPresentation short audio failures get actionable copy") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Invalid audio data provided. Must be at least 1 second of 16kHz audio.",
            shortErrorMessage: "Invalid audio data provided. Must be at least 1 second of 16kHz audio.",
            isRetryable: false
        )

        assertEqual(copy.title, "Recording ended too soon", "short captures should stop looking like generic retries")
        assertEqual(
            copy.detail,
            "Nothing broke - there just was not enough audio to transcribe. Record at least two seconds before stopping.",
            "short captures should explain the intentional terminal outcome"
        )
    }

    runSuite("FailedMeetingPresentation does not classify unrelated minimum-copy as short audio") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Upload failed after at least one retry because the destination was unavailable.",
            shortErrorMessage: "Upload failed after at least one retry.",
            isRetryable: true
        )

        assertEqual(copy.title, "Transcript needs another pass", "generic retry copy should not look like short audio")
        assertEqual(copy.detail, "Upload failed after at least one retry.", "generic retry detail should be preserved")
    }

    runSuite("FailedMeetingPresentation system audio failures point to settings") {
        let copy = MeetingFailureCopy.make(
            forMessage: "System audio is required. Turn on System Audio Recording and retry.",
            shortErrorMessage: "System audio is required. Turn on System Audio Recording and retry.",
            isRetryable: false
        )

        assertEqual(copy.title, "Turn on System Audio Recording", "permission failures should name the missing permission")
        assertEqual(
            copy.detail,
            "Turn on System Audio Recording in System Settings, then retry the meeting.",
            "permission failures should point to the recovery step"
        )
    }

    runSuite("FailedMeetingPresentation microphone failures point to settings") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Turn on Microphone access in System Settings before recording a meeting.",
            shortErrorMessage: "Turn on Microphone access in System Settings before recording a meeting.",
            isRetryable: false
        )

        assertEqual(copy.title, "Turn on Microphone", "microphone failures should name the missing permission")
        assertEqual(
            copy.detail,
            "Turn on Microphone access in System Settings, then retry the meeting.",
            "microphone failures should point to the recovery step"
        )
    }

    runSuite("FailedMeetingPresentation inconclusive checks do not claim permission is off") {
        let copy = MeetingFailureCopy.make(
            forMessage: "System audio didn't start after macOS returned an inconclusive access check.",
            shortErrorMessage: "System audio didn't start.",
            isRetryable: true
        )

        assertEqual(copy.title, "Couldn't verify system audio access", "inconclusive probes need honest copy")
        assertEqual(
            copy.detail,
            "Try again. If it keeps happening, review System Audio Recording in System Settings.",
            "the detail may offer settings as a fallback without asserting denial"
        )
    }

    runSuite("FailedMeetingPresentation capture-start failures do not look like transcript retries") {
        let mic = MeetingFailureCopy.make(
            forMessage: "Microphone didn't start. Check your input device.",
            shortErrorMessage: "Microphone didn't start.",
            isRetryable: true
        )
        let system = MeetingFailureCopy.make(
            forMessage: "System audio couldn't start. Try recording again.",
            shortErrorMessage: "System audio couldn't start.",
            isRetryable: true
        )
        let both = MeetingFailureCopy.make(
            forMessage: "Meeting audio didn't start. Check your audio devices.",
            shortErrorMessage: "Meeting audio didn't start.",
            isRetryable: true
        )

        assertEqual(mic.title, "Microphone didn't start", "mic start failure should name the input")
        assertEqual(system.title, "System audio didn't start", "system start failure should name the stream")
        assertEqual(both.title, "Meeting audio didn't start", "generic start failure should name the capture stage")
    }

    runSuite("FailedMeetingPresentation save failures keep the short error detail") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Failed to save transcript: Could not write transcript to meetings",
            shortErrorMessage: "Could not write transcript to meetings",
            isRetryable: false
        )

        assertEqual(copy.title, "Couldn't save the transcript", "save failures should keep the save-specific title")
        assertEqual(copy.detail, "Could not write transcript to meetings", "save failures should preserve the short write error")
    }

    runSuite("FailedMeetingPresentation no-speech failures point at Try again on the Meetings page") {
        let copy = MeetingFailureCopy.make(
            forMessage: "No speech detected",
            shortErrorMessage: "No speech detected",
            isRetryable: true
        )

        assertEqual(copy.title, "No speech found", "no-speech outcomes should be named plainly")
        assertEqual(
            copy.detail,
            "Transcripted kept the audio but couldn't find spoken words in it. If people were talking, open the Meetings page and choose Try again.",
            "saved no-speech rows offer Try again unless their audio is silent, so the copy points there conditionally"
        )
    }

    runSuite("FailedMeetingPresentation mid-meeting device loss gets device-loss copy, not start-failure copy") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Audio device unavailable — recording stopped after 5 recovery attempts. Reconnect your microphone and try again.",
            shortErrorMessage: "Audio device unavailable — recording stopped after 5 recovery attempts.",
            isRetryable: true
        )

        assertEqual(copy.title, "Audio device disconnected", "the mic watchdog give-up should be named as device loss")
        assertTrue(copy.detail.contains("Reconnect"), "device-loss copy should tell the user to reconnect the device")
        assertFalse(copy.title.contains("didn't start"), "a mid-meeting device loss must not read as a start failure")
    }

    runSuite("FailedMeetingPresentation unusable mic artifacts point to recording repair") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Microphone audio was not usable",
            shortErrorMessage: "Microphone audio was not usable",
            isRetryable: false
        )

        assertEqual(copy.title, "Microphone audio was not captured", "unusable mic artifacts should name the failed source")
        assertEqual(
            copy.detail,
            "Transcripted kept the meeting audio, but the microphone track had no usable signal. Try again to transcribe the other side of the call, then check the selected microphone before your next meeting.",
            "unusable mic artifacts should offer the recovery that actually works before pointing at hardware"
        )
    }

    runSuite("A skipped no-speech transcript surfaces as a visible error") {
        let message = "No speech detected"
        assertTrue(
            MeetingFailureKind.noSpeechDetected.shouldReportAsSkippedTranscript,
            "no-speech failures take the skipped-transcript path"
        )

        let whileTranscribing = MeetingSessionStateMachine.skippedTranscript(
            diagnosticMessage: message,
            while: .transcribing
        )
        assertEqual(whileTranscribing.terminalOutcome, .failed(message), "a skipped transcript ends as a failure, not a save or a discard")
        assertEqual(whileTranscribing.visibleState, .error(message), "with no live capture the error shows right away")
        assertEqual(
            MeetingSessionStateMachine.settledTransition(after: whileTranscribing.terminalOutcome, current: .error(message))?.state,
            .error(message),
            "settling the queue keeps the error visible"
        )

        let duringAnotherMeeting = MeetingSessionStateMachine.skippedTranscript(
            diagnosticMessage: message,
            while: .recording
        )
        assertEqual(duringAnotherMeeting.terminalOutcome, .failed(message))
        assertNil(duringAnotherMeeting.visibleState, "a queued job's skip must not stomp a different meeting that is recording live")
        assertNil(
            MeetingSessionStateMachine.settledTransition(after: duringAnotherMeeting.terminalOutcome, current: .recording),
            "the queue does not settle while capture is live"
        )
        assertEqual(
            MeetingSessionStateMachine.settledTransition(after: duringAnotherMeeting.terminalOutcome, current: .transcribing)?.state,
            .error(message),
            "once that capture ends the skip still surfaces as an error"
        )
    }

    runSuite("The transcription queue settles onto how the last job ended") {
        assertEqual(MeetingSessionStateMachine.settledTransition(after: .transcriptSaved, current: .transcribing)?.state, .ready)
        assertEqual(MeetingSessionStateMachine.settledTransition(after: .discarded, current: .transcribing)?.state, .ready)
        assertEqual(MeetingSessionStateMachine.settledTransition(after: nil, current: .transcribing)?.state, .ready)
        assertNil(MeetingSessionStateMachine.settledTransition(after: nil, current: .ready), "nothing finished and nothing running: stay put")
        assertNil(MeetingSessionStateMachine.settledTransition(after: .transcriptSaved, current: .stoppingRecording), "never settles over a capture still stopping")
    }

    runSuite("HomeFailedMeetingInlinePresentation shows details for non-retryable failures") {
        let presentation = HomeFailedMeetingInlinePresentation.make(
            isRetryable: false,
            isRetrying: false,
            hasAudioFiles: true,
            detail: "Turn on System Audio Recording in System Settings, then retry the meeting."
        )

        assertEqual(presentation.statusText, "Needs attention", "non-retryable rows should not ask for a retry")
        assertEqual(
            presentation.inlineDetail,
            "Turn on System Audio Recording in System Settings, then retry the meeting.",
            "the recovery detail should be visible inline instead of only in a tooltip"
        )
        assertFalse(presentation.canShowRetryAction, "non-retryable failures should not show Try again")
    }

    runSuite("HomeFailedMeetingInlinePresentation explains retryable saved audio") {
        let presentation = HomeFailedMeetingInlinePresentation.make(
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: true,
            detail: "Model was not ready."
        )

        assertEqual(presentation.statusText, "Retry ready", "retryable rows should show that recovery is available")
        assertEqual(
            presentation.inlineDetail,
            "Saved audio is still here. Try again will transcribe it.",
            "retryable rows should make saved audio preservation visible"
        )
        assertTrue(presentation.canShowRetryAction, "retryable failures with audio should show Try again")
    }

    runSuite("HomeFailedMeetingInlinePresentation says why a retryable meeting failed") {
        let permission = HomeFailedMeetingInlinePresentation.make(
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: true,
            detail: "ignored",
            failureKind: .systemAudioPermission
        )
        assertEqual(permission.statusText, "Retry ready")
        assertEqual(
            permission.inlineDetail,
            "Turn on System Audio Recording in System Settings first, then try again.",
            "the fix-first step should be visible inline, not only in a tooltip"
        )
        assertTrue(permission.canShowRetryAction)

        let unknownKind = HomeFailedMeetingInlinePresentation.make(
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: true,
            detail: "ignored",
            failureKind: .transcriptionInferenceFailed
        )
        assertEqual(
            unknownKind.inlineDetail,
            "Saved audio is still here. Try again will transcribe it.",
            "kinds where Try again is the whole answer keep the saved-audio line"
        )

        for kind in [
            MeetingFailureKind.systemAudioPermission,
            .systemAudioPermissionCheckInconclusive,
            .microphonePermission,
            .languageNeedsWhisperModel,
            .modelDownloadFailed,
            .modelNotLoaded,
            .microphoneAudioUnusable,
            .audioDeviceUnavailable,
            .stopTimeout,
            .savedBeforeQuit,
            .speakerNameFinalizationFailed,
            .speakerFinalizationFailed,
            .saveFailed
        ] {
            let reason = HomeFailedMeetingInlinePresentation.retryReason(for: kind) ?? ""
            assertFalse(reason.isEmpty, "\(kind.rawValue) should explain itself on Home")
            assertFalse(reason.contains("Home"), "Home copy should not tell people to open Home (\(kind.rawValue))")
        }
    }

    runSuite("HomeFailedMeetingInlinePresentation does not call saved transcripts failed meetings") {
        let namesOnly = HomeFailedMeetingInlinePresentation.attentionSummary(
            failureKinds: [.speakerNameFinalizationFailed, .speakerFinalizationFailed, .speakerNameFinalizationFailed]
        )
        assertEqual(namesOnly.title, "3 meetings need speaker names")
        assertTrue(namesOnly.onlySpeakerNamesMissing, "a pile of speaker-name failures keeps its transcripts")
        assertFalse(namesOnly.title.contains("failed"), "saved transcripts should not read as failed meetings")

        let single = HomeFailedMeetingInlinePresentation.attentionSummary(failureKinds: [.speakerFinalizationFailed])
        assertEqual(single.title, "1 meeting needs speaker names")

        let mixed = HomeFailedMeetingInlinePresentation.attentionSummary(
            failureKinds: [.speakerNameFinalizationFailed, .saveFailed]
        )
        assertEqual(mixed.title, "2 meetings failed", "any real failure keeps the failed wording")
        assertFalse(mixed.onlySpeakerNamesMissing)

        let names = HomeFailedMeetingInlinePresentation.retryReason(for: .speakerNameFinalizationFailed) ?? ""
        assertTrue(names.contains("transcript is saved"), "the row should say the transcript survived")
    }

    runSuite("HomeFailedMeetingInlinePresentation stop-timeout retained audio appears retry-ready in Home") {
        let directory = makeFailedMeetingPresentationTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let micURL = directory.appendingPathComponent("microphone.wav")
        let systemURL = directory.appendingPathComponent("system_audio.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        FileManager.default.createFile(atPath: systemURL.path, contents: Data("system".utf8))

        let hasAudioFiles = FileManager.default.fileExists(atPath: micURL.path)
            && FileManager.default.fileExists(atPath: systemURL.path)
        let presentation = HomeFailedMeetingInlinePresentation.make(
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: hasAudioFiles,
            detail: "Recording stop timed out before audio files were finalized."
        )

        assertEqual(
            MeetingFailureKind.classify(message: "Recording stop timed out before audio files were finalized."),
            .stopTimeout,
            "stop-timeout failures should keep their recovery category"
        )
        assertTrue(hasAudioFiles, "retained timeout audio should make the Home row retry-ready")
        assertEqual(presentation.statusText, "Retry ready", "Home should show that saved audio can be retried")
        assertEqual(
            presentation.inlineDetail,
            "Saved audio is still here. Try again will transcribe it.",
            "Home should make the recovery path visible"
        )
        assertTrue(presentation.canShowRetryAction, "retained stop-timeout audio should show Try again")
    }

    runSuite("HomeFailedMeetingInlinePresentation blocks retries when audio is gone") {
        let presentation = HomeFailedMeetingInlinePresentation.make(
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: false,
            detail: "Model was not ready."
        )

        assertEqual(presentation.statusText, "Audio missing", "missing audio should not look like a normal retry")
        assertEqual(
            presentation.inlineDetail,
            "Saved audio is missing, so this meeting cannot be retried.",
            "missing audio should explain why Try again is unavailable"
        )
        assertFalse(presentation.canShowRetryAction, "missing audio should suppress Try again")
    }

    runSuite("HomeFailedMeetingInlinePresentation suppresses retry for audio probed as silent") {
        let presentation = HomeFailedMeetingInlinePresentation.make(
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: true,
            detail: "Microphone audio was not usable.",
            usableAudio: .absent
        )

        assertEqual(
            presentation.statusText,
            "No sound saved",
            "silent audio is a different situation from audio that is gone"
        )
        assertEqual(
            presentation.inlineDetail,
            "The saved audio is silent, so there is nothing to transcribe.",
            "silent audio should say why retrying cannot help"
        )
        assertFalse(
            presentation.canShowRetryAction,
            "a retry that can only reproduce the same failure should not be offered"
        )
    }

    runSuite("HomeFailedMeetingInlinePresentation keeps retry visible while the audio probe is pending") {
        // This is the case Matthew's stuck rows land in on first render: the
        // failure message no longer suppresses the action, and the probe has not
        // reported yet. Offering retry optimistically matches the old behavior
        // and avoids an action that pops in a moment later.
        let presentation = HomeFailedMeetingInlinePresentation.make(
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: true,
            detail: "Microphone audio was not usable.",
            usableAudio: .unknown
        )

        assertEqual(presentation.statusText, "Retry ready")
        assertTrue(presentation.canShowRetryAction, "an unprobed row should still offer retry")
    }

    runSuite("HomeFailedMeetingInlinePresentation reports a running retry over a silent verdict") {
        let presentation = HomeFailedMeetingInlinePresentation.make(
            isRetryable: true,
            isRetrying: true,
            hasAudioFiles: true,
            detail: "Microphone audio was not usable.",
            usableAudio: .absent
        )

        assertEqual(presentation.statusText, "Retrying", "an in-flight retry outranks a stale probe verdict")
        assertTrue(presentation.canShowRetryAction)
    }

    runSuite("FailedMeetingPresentation speaker-name failures stay speaker-specific") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Speaker names could not be saved. The transcript saved, but speaker-name finalization failed.",
            shortErrorMessage: "Speaker names could not be saved.",
            isRetryable: true
        )

        assertEqual(copy.title, "Couldn't save speaker names", "speaker finalization failures should not look like full transcript failures")
        assertTrue(copy.detail.contains("transcript saved"), "copy should say the transcript itself was saved")
    }

    runSuite("A failed row can reveal a lone mic placeholder but cannot retry it") {
        let directory = makeFailedMeetingPresentationTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let placeholder = writeFailedMeetingAudio(in: directory, named: "microphone_placeholder.wav")
        let failed = FailedTranscription(
            micAudioURL: placeholder,
            systemAudioURL: directory.appendingPathComponent("system_audio.wav"),
            errorMessage: "Model not loaded"
        )
        let item = FailedMeetingPresentation.item(from: failed, isRetrying: false)

        assertEqual(item.audioURLs, [placeholder], "audio still on disk stays revealable, even a placeholder")
        assertFalse(item.hasAudioFiles, "a silent placeholder alone must not make the row retry-ready")
    }

    runSuite("A failed row with surviving audio is revealable and retry-ready") {
        let directory = makeFailedMeetingPresentationTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let mic = writeFailedMeetingAudio(in: directory, named: "microphone.wav")
        let system = writeFailedMeetingAudio(in: directory, named: "system_audio.wav")
        let both = FailedMeetingPresentation.item(
            from: FailedTranscription(micAudioURL: mic, systemAudioURL: system, errorMessage: "Model not loaded"),
            isRetrying: false
        )
        assertEqual(both.audioURLs, [system, mic], "every surviving file is revealable, system audio first")
        assertTrue(both.hasAudioFiles, "complete retained audio makes the row retry-ready")

        let systemOnly = FailedMeetingPresentation.item(
            from: FailedTranscription(
                micAudioURL: directory.appendingPathComponent("gone.wav"),
                systemAudioURL: system,
                errorMessage: "Model not loaded"
            ),
            isRetrying: false
        )
        assertEqual(systemOnly.audioURLs, [system], "a missing file is not offered for reveal")
        assertTrue(systemOnly.hasAudioFiles, "a missing mic file must not hide retry while system audio survives")
    }

    runSuite("A failed row whose audio is gone offers neither reveal nor retry") {
        let directory = makeFailedMeetingPresentationTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let item = FailedMeetingPresentation.item(
            from: FailedTranscription(
                micAudioURL: directory.appendingPathComponent("microphone.wav"),
                systemAudioURL: directory.appendingPathComponent("system_audio.wav"),
                errorMessage: "Model not loaded"
            ),
            isRetrying: false
        )

        assertEqual(item.audioURLs, [], "nothing on disk means nothing to reveal")
        assertFalse(item.hasAudioFiles, "nothing on disk means nothing to retry")
    }

    runSuite("A failed row carries no non-destructive cleanup state") {
        let item = FailedMeetingPresentation.item(
            from: FailedTranscription(
                micAudioURL: URL(fileURLWithPath: "/nonexistent/microphone.wav"),
                systemAudioURL: nil,
                errorMessage: "Model not loaded"
            ),
            isRetrying: false
        )
        let fields = Mirror(reflecting: item).children.compactMap(\.label)

        assertTrue(fields.contains("audioURLs"), "the reflection should see the row's stored fields")
        assertFalse(
            fields.contains("deletionRemovesAudio"),
            "cleaning up a failed row always deletes its audio, so the row has no flag saying otherwise"
        )
    }

    runSuite("A failed row carries the failure's identity, copy, typed kind, and audio verdict") {
        let longMessage = "Transcription stopped because something unexpected happened in the pipeline "
            + "while it was working through the recording."
        let failed = FailedTranscription(
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            micAudioURL: URL(fileURLWithPath: "/nonexistent/microphone.wav"),
            systemAudioURL: nil,
            errorMessage: longMessage,
            errorKind: .missingSystemAudio
        )
        let item = FailedMeetingPresentation.item(from: failed, isRetrying: false, usableAudio: .absent)

        assertEqual(item.id, failed.id)
        assertEqual(item.timestamp, failed.timestamp)
        assertEqual(item.failureKind, .systemAudioPermission, "the typed error kind wins over the message text")
        assertTrue(item.isRetryable, "a single-source failure keeps its saved audio retryable")
        assertFalse(item.isRetrying)
        assertEqual(item.usableAudio, .absent, "the audio probe verdict reaches the row")
        assertEqual(
            item.detail,
            String(longMessage.prefix(97)) + "...",
            "unmapped failures show the shortened error, not the whole message"
        )
    }

    runSuite("Home failed meeting row reveals partial audio separately from retry readiness") {
        func row(
            isRetryable: Bool = true,
            hasAudioFiles: Bool = true,
            audioURLs: [URL] = [URL(fileURLWithPath: "/tmp/synthetic-meeting_mic.wav")],
            usableAudio: FailedMeetingUsableAudio = .unknown,
            canRetry: Bool = true
        ) -> HomeFailedMeetingRowActions {
            HomeFailedMeetingRowActions.make(
                item: FailedMeetingPresentation.FailedMeetingItem(
                    id: UUID(),
                    timestamp: Date(timeIntervalSince1970: 0),
                    title: "Synthetic meeting",
                    detail: "synthetic detail",
                    meta: "",
                    failureKind: .saveFailed,
                    isRetryable: isRetryable,
                    isRetrying: false,
                    hasAudioFiles: hasAudioFiles,
                    audioURLs: audioURLs,
                    usableAudio: usableAudio
                ),
                canRetry: canRetry
            )
        }

        let complete = row()
        assertTrue(complete.showsRevealAudio, "kept audio can be shown in Finder")
        assertFalse(complete.retryDisabled, "complete retryable audio keeps Try again available")

        let partial = row(hasAudioFiles: false)
        assertTrue(partial.showsRevealAudio, "a partial set of kept audio stays revealable")
        assertTrue(partial.retryDisabled, "partial audio is not enough to retry")

        assertTrue(row(isRetryable: false).showsRevealAudio, "a non-retryable row still shows its kept audio")
        assertTrue(row(isRetryable: false).retryDisabled, "a non-retryable row can't retry")
        assertTrue(row(usableAudio: .absent).retryDisabled, "audio probed as silent must not offer retry")
        assertTrue(row(canRetry: false).retryDisabled, "a busy queue blocks retry")

        let noAudio = row(hasAudioFiles: false, audioURLs: [])
        assertFalse(noAudio.showsRevealAudio, "with no kept audio there is nothing to show")

        assertEqual(complete.deleteTitle, "Delete failed meeting", "cleanup is labeled as a delete")
        assertTrue(complete.deleteIsDestructive, "cleanup is marked destructive")
    }

    runSuite("Settings confirms every failed-row cleanup as a delete") {
        let settingsSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/TranscriptedSettingsView.swift"),
            encoding: .utf8
        )) ?? ""
        assertTrue(
            settingsSource.contains("requestClearFailedMeeting")
                && settingsSource.contains("HomeDeleteConfirmationPolicy.failedMeeting")
                && settingsSource.contains("reasonKind: .deleted"),
            "Home should confirm and report every failed-row cleanup as deletion, not dismissal"
        )
        assertFalse(
            settingsSource.contains("dismissFailedMeeting"),
            "failed-row cleanup should have one canonical destructive seam"
        )
    }

    runSuite("Failed-meeting metadata calls retained WAVs raw audio and counts only files still on disk") {
        let directory = makeFailedMeetingPresentationTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Size and timestamp text are read while the files exist. The size is
        // whatever the shared formatter prints, so the test doesn't pin it.
        func meta(mic: String, system: String?, onDisk: Set<String>) -> (meta: String, stamp: String, size: String) {
            for name in onDisk { _ = writeFailedMeetingAudio(in: directory, named: name) }
            defer {
                for name in onDisk { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
            }
            let failed = FailedTranscription(
                micAudioURL: directory.appendingPathComponent(mic),
                systemAudioURL: system.map { directory.appendingPathComponent($0) },
                errorMessage: "Model not loaded"
            )
            let item = FailedMeetingPresentation.item(from: failed, isRetrying: false)
            return (item.meta, failed.formattedTimestamp, failed.formattedFileSize)
        }

        let wav = meta(mic: "microphone.wav", system: "system_audio.wav", onDisk: ["microphone.wav", "system_audio.wav"])
        assertTrue(wav.size != "Unknown", "both files on disk should give a known size")
        assertEqual(
            wav.meta,
            "\(wav.stamp) • \(wav.size) raw audio kept",
            "retained WAVs read as raw audio with their size"
        )

        let upper = meta(mic: "microphone.m4a", system: "system_audio.WAV", onDisk: ["microphone.m4a", "system_audio.WAV"])
        assertEqual(
            upper.meta,
            "\(upper.stamp) • \(upper.size) raw audio kept",
            "the WAV check ignores extension case"
        )

        let compressed = meta(mic: "microphone.m4a", system: "system_audio.m4a", onDisk: ["microphone.m4a", "system_audio.m4a"])
        assertEqual(
            compressed.meta,
            "\(compressed.stamp) • \(compressed.size) kept",
            "compressed audio is kept audio, not raw audio"
        )

        let rawNoSize = meta(mic: "microphone.wav", system: "system_audio.wav", onDisk: ["system_audio.wav"])
        assertEqual(
            rawNoSize.meta,
            "\(rawNoSize.stamp) • Raw audio kept",
            "a WAV whose total size can't be read still reads as raw audio"
        )

        let keptNoSize = meta(mic: "microphone.m4a", system: "system_audio.m4a", onDisk: ["system_audio.m4a"])
        assertEqual(
            keptNoSize.meta,
            "\(keptNoSize.stamp) • Audio kept",
            "compressed audio with no readable size still says audio was kept"
        )

        let deletedWAV = meta(mic: "microphone.wav", system: "system_audio.m4a", onDisk: ["system_audio.m4a"])
        assertEqual(
            deletedWAV.meta,
            "\(deletedWAV.stamp) • Audio kept",
            "a WAV that is no longer on disk must not make the row claim raw audio"
        )

        let nothing = meta(mic: "microphone.wav", system: "system_audio.wav", onDisk: [])
        assertEqual(nothing.meta, nothing.stamp, "no audio on disk means no kept-audio label")
    }

    runSuite("Failed-meeting rows show the meeting title, retry count, and a running retry") {
        let noAudio = URL(fileURLWithPath: "/nonexistent/microphone.wav")
        func row(
            title: String? = nil,
            message: String = "Model not loaded",
            errorKind: PipelineErrorKind? = nil,
            retryCount: Int = 0,
            isRetrying: Bool = false
        ) -> (item: FailedMeetingPresentation.FailedMeetingItem, failed: FailedTranscription) {
            let failed = FailedTranscription(
                micAudioURL: noAudio,
                systemAudioURL: nil,
                errorMessage: message,
                meetingTitle: title,
                retryCount: retryCount,
                errorKind: errorKind
            )
            return (FailedMeetingPresentation.item(from: failed, isRetrying: isRetrying), failed)
        }

        assertEqual(row(title: "  Weekly sync \n").item.title, "Weekly sync", "a queued meeting keeps its own title, trimmed")
        assertEqual(
            row(title: "   ", message: "Something unexpected happened.").item.title,
            "Meeting transcript failed",
            "an untitled generic retry reads as a failed meeting transcript"
        )
        assertEqual(
            row(message: "Something unexpected happened.", errorKind: .recordingTooShort).item.title,
            "Recording needs attention",
            "an untitled non-retryable failure keeps its copy title"
        )
        assertEqual(
            row(message: "No speech detected").item.title,
            "No speech found",
            "an untitled row with specific copy uses that copy's title"
        )

        let fresh = row()
        assertEqual(fresh.item.meta, fresh.failed.formattedTimestamp, "a row never retried shows no retry count")

        let once = row(retryCount: 1)
        assertEqual(once.item.meta, "\(once.failed.formattedTimestamp) • 1 retry")

        let many = row(retryCount: 3)
        assertEqual(many.item.meta, "\(many.failed.formattedTimestamp) • 3 retries")

        let running = row(retryCount: 1, isRetrying: true)
        assertTrue(running.item.isRetrying, "the row knows a retry is running")
        assertEqual(
            running.item.meta,
            "\(running.failed.formattedTimestamp) • 1 retry • Retrying now",
            "a running retry shows last in the row metadata"
        )
    }
}

private func makeFailedMeetingPresentationTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FailedMeetingPresentationTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeFailedMeetingAudio(in directory: URL, named name: String) -> URL {
    let url = directory.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x2A, count: 4096))
    return url
}

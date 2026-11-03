// MeetingOverlayController+Island.swift
// What the Notch island shows for the meeting, and what its taps and
// right-click menu do: Stop, Open, the prompt buttons, the call-audio chip
// and Discard. Split out of MeetingOverlayController.swift to keep it under
// the file-size limit.

import AppKit

extension MeetingOverlayController {
    /// Discard lives behind the island's right-click menu (with this confirmation)
    /// rather than as a permanent button: deleting a recording is a rare,
    /// deliberate act and must never sit one mis-click from Stop.
    private func handleDiscardRequested() {
        guard !isShowingCancelConfirmation else { return }
        guard let session = meetingSession else { return }
        guard MeetingSessionStateMachine.mayDiscardRecording(sessionState: session.state) else { return }

        isShowingCancelConfirmation = true
        defer {
            isShowingCancelConfirmation = false
        }

        MeetingSessionStateMachine.discardRecordingIfConfirmed(sessionState: { session.state }, confirm: {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Discard this meeting recording?"
            alert.informativeText = "This will stop the meeting recording and delete the captured audio. No transcript will be saved."
            alert.addButton(withTitle: "Keep Recording")
            alert.addButton(withTitle: "Discard Recording")
            alert.buttons.last?.hasDestructiveAction = true
            return alert.runModal() == .alertSecondButtonReturn
        }, discard: {
            // A confirm can outlive Stop; the flow rechecks before canceling.
            Task { [weak session] in await session?.cancelRecording(reason: .discardButton) }
        })
    }

    private func handleSecondaryActionTapped() {
        switch state {
        case .prompt:
            switch promptKind {
            case .systemAudio:
                meetingSession?.acknowledgeSystemAudioDegradationWarning()
            case .audioInactivity:
                meetingSession?.dismissAudioInactivityWarning()
            case .micBoost:
                meetingSession?.declineMicBoostPrompt()
            case .audioRoute:
                meetingSession?.dismissAudioRouteWarning()
            case .missedCall:
                // "Don't show again" — the wiring persists the opt-out.
                onMissedCallNudgeResolved?(.disabled)
                dismissPrompt()
            case .none:
                dismissPrompt()
            }
        case .recording:
            handleCloseTapped()
        default:
            hidePanel()
        }
    }

    private func handlePrimaryActionTapped() {
        switch state {
        case .saved:
            openMeetingsFromPill(transcriptURL: savedTranscriptURL)
            return
        case .error:
            // A start that macOS refused for System Audio Recording: the one
            // fix is that Settings pane, then a new recording.
            if meetingSession?.systemAudioPermissionRecoveryNeeded == true {
                TranscriptedPermissionAccess.openSystemAudioRecordingSettings()
                return
            }
            openMeetingsFromPill(transcriptURL: nil)
            return
        default:
            break
        }
        guard case .prompt = state else { return }
        promptCountdownTask?.cancel()

        switch promptKind {
        case .systemAudio:
            Task { @MainActor [weak self] in
                guard let session = self?.meetingSession else { return }
                await session.stopRecording(reason: .systemAudioWarning)
            }
        case .audioInactivity:
            let warning = meetingSession?.audioInactivityWarning
            Task { @MainActor [weak self] in
                guard let session = self?.meetingSession else { return }
                await session.endRecordingFromAudioInactivityPrompt(automatic: false, expectedWarning: warning)
            }
        case .audioRoute:
            Task { @MainActor [weak self] in
                guard let session = self?.meetingSession else { return }
                await session.stopRecording(reason: .audioRouteWarning)
            }
        case .micBoost:
            // Session clears the published flag, which the combined warning
            // subscription picks up and resolves back down to .recording (or
            // to whichever prompt was suppressed behind this one).
            meetingSession?.acceptMicBoostPrompt()
        case .missedCall:
            onMissedCallNudgeResolved?(.acknowledged)
            dismissPrompt()
        case .none:
            break
        }
    }

    /// The pill's "Mic only" note, or Check Access on the system audio
    /// warning. Both send the user to turn call audio on.
    private func handleCallAudioActionTapped() {
        switch state {
        case .prompt:
            guard promptKind == .systemAudio else { return }
            meetingSession?.checkSystemAudioAccessFromWarning()
        case .recording:
            guard micOnlyNotice == .callAudioOff else { return }
            Task { @MainActor [weak self] in
                await self?.meetingSession?.turnOnCallAudioFromMicOnlyNotice()
            }
        default:
            break
        }
    }

    // MARK: - Island right-click menu

    func makeStripMenu() -> NSMenu? {
        // Overlay `.recording` also covers `.stoppingRecording`; the session state decides.
        if MeetingSessionStateMachine.stripMenuOffersDiscard(overlayIsRecording: state == .recording, sessionState: meetingSession?.state) {
            let menu = NSMenu()
            let discardItem = NSMenuItem(
                title: "Discard Recording…",
                action: #selector(handleMenuDiscard),
                keyEquivalent: ""
            )
            discardItem.target = self
            menu.addItem(discardItem)
            return menu
        }
        return nil
    }

    @objc private func handleMenuDiscard() {
        handleDiscardRequested()
    }

    // MARK: - Notch island

    func islandContent() -> NotchIslandMeetingContent {
        let sessionState = meetingSession?.state
        let phase: NotchIslandMeetingContent.Phase
        switch state {
        case .idle:
            phase = .none
        case .prompt:
            // Warning prompts arrive mid-recording; the missed-call nudge
            // arrives with nothing recording.
            switch sessionState {
            case .recording?, .stoppingRecording?:
                phase = .recording
            default:
                phase = .none
            }
        case .preparing where currentWarmupStatus.progress >= 1:
            // Models are ready; the mic and call audio are what's starting.
            phase = .preparing(title: "Starting…", detail: "Checking your mic and call audio")
        case .preparing:
            phase = .preparing(
                title: currentWarmupStatus.title,
                detail: currentWarmupStatus.subtitle.isEmpty ? currentWarmupStatus.detail : currentWarmupStatus.subtitle
            )
        case .recording:
            phase = .recording
        case .transcribing:
            phase = .transcribing(
                progress: MeetingPillFinishPresentation.percent(progress: currentTranscriptionProgress).map { Double($0) / 100 },
                detail: finishDetail
            )
        case .saved:
            phase = .saved(title: savedTranscriptTitle)
        case .error(let message):
            let copy = MeetingFailureCopy.make(forMessage: message, shortErrorMessage: message, isRetryable: true)
            phase = .error(
                title: copy.title,
                message: copy.detail,
                canOpen: MeetingPillFinishPresentation.errorOffersOpenMeetings(
                    failureKind: MeetingFailureKind.classify(message: message),
                    hasFailedMeetingRowForError: hasFailedMeetingRowForCurrentError
                ),
                grantsSystemAudio: meetingSession?.systemAudioPermissionRecoveryNeeded == true
            )
        }
        let prompt = currentPrompt.map {
            NotchIslandMeetingContent.Prompt(
                title: $0.title,
                detail: $0.detail,
                countdown: $0.countdownText,
                primaryTitle: $0.primaryTitle,
                secondaryTitle: $0.secondaryTitle,
                tertiaryTitle: $0.tertiaryTitle
            )
        }
        var callAudioNote: NotchIslandMeetingContent.CallAudioNote?
        switch showsMicOnlyNote ? micOnlyNotice : nil {
        case .callAudioOff?:
            callAudioNote = .off
        case .callAudioOnForNextMeeting?:
            callAudioNote = .onForNextMeeting
        case nil:
            callAudioNote = nil
        }
        return NotchIslandMeetingContent(
            phase: phase,
            prompt: state == .prompt ? prompt : nil,
            duration: currentDuration,
            callAudioNote: callAudioNote,
            systemAudioUnverified: systemAudioDegradationWarning?.cause == .unverified,
            asksAboutCallAudio: islandCallAudioAskPending,
            autoRecordNote: autoRecordNoteVisible
        )
    }

    /// Quiet for a few seconds after an opt-in auto-start. Yields to the
    /// call-audio ask so that prompt still owns the island.
    var autoRecordNoteVisible: Bool {
        MeetingAutoRecordNoteCopy.isVisible(
            duration: currentDuration,
            asksAboutCallAudio: islandCallAudioAskPending,
            noteEnabled: state == .recording && meetingSession?.activeRecordingWasAutoStarted == true
        )
    }

    func handleIslandAction(_ action: NotchIslandAction) {
        switch MeetingAutoRecordIslandActionPolicy.route(
            action: action,
            noteVisible: autoRecordNoteVisible,
            overlayPromptActive: state == .prompt || islandCallAudioAskPending
        ) {
        case .stop:
            handleCloseTapped()
            return
        case .discard:
            handleDiscardRequested()
            return
        case .inherit:
            break
        }
        switch action {
        case .meetingCallAudioDismiss:
            islandCallAudioAskPending = false
            meetingSession?.dismissCallAudioAsk()
            pushToView()
        case .meetingStop, .meetingDismissError:
            handleCloseTapped()
        case .meetingPrimary, .meetingOpen:
            handlePrimaryActionTapped()
        case .meetingSecondary:
            handleSecondaryActionTapped()
        case .meetingTertiary:
            handleCallAudioActionTapped()
        case .meetingCallAudio:
            // The "Mic only" chip, which can show under a warning prompt too.
            islandCallAudioAskPending = false
            meetingSession?.dismissCallAudioAsk()
            guard micOnlyNotice == .callAudioOff else {
                pushToView()
                return
            }
            Task { @MainActor [weak self] in
                await self?.meetingSession?.turnOnCallAudioFromMicOnlyNotice()
            }
        default:
            break
        }
    }
}

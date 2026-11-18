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
        guard let session = meetingSession, let id = session.activeRecordingIdentity else { return }
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
            Task { [weak session] in
                guard let session, session.activeRecordingIdentity == id else { return }
                await session.cancelRecording(reason: .discardButton)
            }
        })
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
    }

    func promptIsCurrent(_ identity: MeetingIslandPromptIdentity) -> Bool {
        guard let session = meetingSession else { return false }
        guard state == .prompt, renderedPromptIdentity == identity else { return false }
        if case .missedCall = identity { return promptKind == .missedCall && !session.isRecording }
        guard session.isRecording, let currentID = session.activeRecordingIdentity,
              MeetingPromptPriority.resolve(
                inactivity: session.audioInactivityWarning, systemAudio: session.systemAudioDegradationWarning,
                routeActive: session.currentRouteWarning != nil, micBoostVisible: session.isMicBoostPromptVisible,
                current: promptKind, isRecording: true, splitOffered: session.meetingSplitOffer != nil
              ) == promptKind else { return false }
        switch identity {
        case .autoRecord, .missedCall: return false
        case .split(let offer):
            return currentID == offer.recordingIdentity
                && offer.matches(session.meetingSplitOffer)
        case .systemAudio(let id, let warning):
            return currentID == id && session.systemAudioDegradationWarning == warning
        case .inactivity(let id, let warning):
            return currentID == id && session.audioInactivityWarning == warning
        case .route(let id, let warning):
            return currentID == id && session.currentRouteWarning == warning
        case .boost(let id):
            return currentID == id && session.isMicBoostPromptVisible
        }
    }

    private func dispatchPromptButton(_ button: MeetingIslandPromptButton, identity: MeetingIslandPromptIdentity) {
        guard promptIsCurrent(identity), let session = meetingSession else { return }
        switch (button, identity) {
        case (.primary, .systemAudio), (.primary, .route), (.primary, .inactivity), (.primary, .split):
            Task { @MainActor [weak self] in
                guard self?.promptIsCurrent(identity) == true else { return }
                switch identity {
                case .systemAudio: await session.stopRecording(reason: .systemAudioWarning)
                case .route: await session.stopRecording(reason: .audioRouteWarning)
                case .inactivity(_, let warning):
                    await session.endRecordingFromAudioInactivityPrompt(automatic: false, expectedWarning: warning)
                case .split(let offer): await session.acceptMeetingSplit(offer)
                default: break
                }
            }
        case (.secondary, .split(let offer)): session.declineMeetingSplit(offer)
        case (.secondary, .systemAudio): session.acknowledgeSystemAudioDegradationWarning()
        case (.tertiary, .systemAudio): session.checkSystemAudioAccessFromWarning()
        case (.secondary, .route): session.dismissAudioRouteWarning()
        case (.secondary, .inactivity): session.dismissAudioInactivityWarning()
        case (.primary, .boost): session.acceptMicBoostPrompt()
        case (.secondary, .boost): session.declineMicBoostPrompt()
        case (.primary, .missedCall), (.secondary, .missedCall):
            onMissedCallNudgeResolved?(button == .primary ? .acknowledged : .disabled)
            dismissPrompt()
        default: break
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
                tertiaryTitle: $0.tertiaryTitle,
                identity: renderedPromptIdentity,
                primaryAccessibilityLabel: $0.primaryAccessibilityLabel,
                secondaryAccessibilityLabel: $0.secondaryAccessibilityLabel,
                tertiaryAccessibilityLabel: $0.tertiaryAccessibilityLabel
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
            recordingID: meetingSession?.activeRecordingIdentity,
            micMuteControlEnabled: NotchIslandPreferences.meetingMicMuteControlEnabled(),
            micMuted: meetingSession?.isMeetingMicMuted == true,
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
        func autoRecordRoute() -> MeetingAutoRecordIslandActionPolicy.Route {
            MeetingAutoRecordIslandActionPolicy.route(action: action, noteVisible: autoRecordNoteVisible,
                recordingID: meetingSession?.activeRecordingIdentity)
        }
        switch autoRecordRoute() {
        case .stop:
            Task { @MainActor in
                guard autoRecordRoute() == .stop else { return }
                await meetingSession?.stopRecording(reason: .overlayStopButton)
            }
            return
        case .discard:
            handleDiscardRequested()
            return
        case .inherit: break
        }
        switch action {
        case .meetingCallAudioDismiss:
            islandCallAudioAskPending = false
            meetingSession?.dismissCallAudioAsk()
            pushToView()
        case .meetingPrompt(let button, let identity):
            dispatchPromptButton(button, identity: identity)
        case .meetingMicMute(let id), .meetingMicUnmute(let id):
            meetingSession?.setMeetingMicMuted(action == .meetingMicMute(id), recordingID: id)
            pushToView()
        case .meetingStop(let recordingID):
            Task { @MainActor [weak self] in
                guard let session = self?.meetingSession, session.isRecording,
                      session.activeRecordingIdentity == recordingID else { return }
                await session.stopRecording(reason: .overlayStopButton)
            }
        case .meetingDismissError:
            dismissError()
        case .meetingOpen:
            handlePrimaryActionTapped()
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

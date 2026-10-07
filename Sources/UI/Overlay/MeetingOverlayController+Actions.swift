// MeetingOverlayController+Actions.swift
// Island action handlers and the right-click menu for the meeting overlay.

import AppKit
import Combine
import TranscriptedCore

@available(macOS 14.0, *)
extension MeetingOverlayController {

    /// Discard lives behind the island's right-click menu (with this confirmation)
    /// rather than as a permanent button: deleting a recording is a rare,
    /// deliberate act and must never sit one mis-click from Stop.
    private func handleDiscardRequested() {
        guard !isShowingCancelConfirmation else { return }
        guard let session = meetingSession else { return }
        guard case .recording = session.state else { return }

        isShowingCancelConfirmation = true
        defer {
            isShowingCancelConfirmation = false
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard this meeting recording?"
        alert.informativeText = "This will stop the meeting recording and delete the captured audio. No transcript will be saved."
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Discard Recording")
        alert.buttons.last?.hasDestructiveAction = true

        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else { return }
        // The confirm sheet can outlive the recording. Stop or an unexpected
        // capture end may already be preserving audio — do not cancel then.
        guard case .recording = session.state else { return }

        Task { [weak session] in
            await session?.cancelRecording(reason: .discardButton)
        }
    }

    func scheduleAutoHide(after seconds: Double) {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Someone reading the saved pill or reaching for Open keeps it
            // up. Checked here instead of trusting hover events, which can
            // be missed when the pill appears under the pointer.
            if case .saved = self.state, self.pointerIsOverPanel() {
                self.scheduleAutoHide(after: MeetingPillFinishPresentation.savedPillHoverOutDwellSeconds)
                return
            }
            self.hidePanel()
        }
    }

    func handleCloseTapped() {
        if case .error = state {
            state = .idle
            hidePanel()
            pushToView()
            return
        }
        guard let session = meetingSession else { hidePanel(); return }
        Task { [weak session] in
            guard let session else { return }
            if case .recording = session.state {
                await session.stopRecording(reason: .overlayStopButton)
            }
        }
    }

    func handleSecondaryActionTapped() {
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

    func handlePrimaryActionTapped() {
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
            Task { @MainActor [weak self] in
                guard let session = self?.meetingSession else { return }
                await session.endRecordingFromAudioInactivityPrompt(automatic: false)
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

    private func openMeetingsFromPill(transcriptURL: URL?) {
        autoHideTask?.cancel()
        state = .idle
        hidePanel()
        pushToView()
        onOpenMeetings?(transcriptURL)
    }

    /// The pill's "Mic only" note, or Check Access on the system audio
    /// warning. Both send the user to turn call audio on.
    func handleCallAudioActionTapped() {
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
        guard state == .recording else { return nil }
        // Overlay `.recording` also covers `.stoppingRecording` (keep the
        // meeting up through teardown). Discard must require the session
        // itself to still be `.recording`, or the item no-ops after a stop starts.
        if case .recording = meetingSession?.state {
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
}

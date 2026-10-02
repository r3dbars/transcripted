// MeetingSessionController+Subscriptions.swift
// Combine wiring on capture, the task manager, the failed queue, STT and
// diarization, plus the background transcript restyle.

import AppKit
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    // MARK: - Subscriptions

    func wireSubscriptions() {
        NotificationCenter.default.publisher(for: .meetingArtifactRecoveryJournalUnavailable)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let directory = notification.object as? URL else { return }
                self?.reportArtifactRecoveryJournalUnavailable(directory)
            }
            .store(in: &cancellables)

        capture.$isRecording
            .sink { [weak self] captureIsRecording in
                guard let self else { return }
                // This is an event handler, not a mirror: `isRecording` is
                // computed from `state` now (audit 2026-08 state-collapse),
                // so this sink no longer writes it, and — deliberately —
                // does NOT promote .startingRecording to .recording here.
                // `capture.$isRecording` mirrors Core's `audio.isRecording`,
                // which flips true as soon as the engine starts, well before
                // `capture.startRecording()`'s own continuation resolves
                // (that requires BOTH mic and system streams to validate
                // buffers — see AudioCaptureStartState.meetingCaptureOutcome
                // and MeetingCaptureBridge.finishPendingStartAttemptIfPossible).
                // Promoting on this earlier signal opened a real race: a
                // stop/cancel could observe the premature .recording, run to
                // completion (e.g. reaching .transcribing), and then the
                // still-pending original startRecording() call could resolve
                // `started == false` afterward and stomp that with .error.
                // startRecording() alone owns the .startingRecording ->
                // .recording transition, synchronously, right after its own
                // `await capture.startRecording()` returns true — that is
                // the only point that has actually observed the real
                // "ready" outcome, not just the early isRecording flip.
                //
                // This sink still does the one job that must react to every
                // stop, expected or not: cleanup that must never outlive a
                // recording, because capture can stop underneath the
                // controller (device watchdog give-up, disk-full guard)
                // without any app-side stop path running. The actual state
                // transition for THAT case — moving to .error — stays in
                // handleUnexpectedCaptureStop(_:), driven by
                // capture.onUnexpectedRecordingComplete with the real
                // CaptureStopResult (audio URLs) needed to preserve a failed
                // meeting; this sink has no URLs to do that safely itself.
                let event: MeetingAudioInactivityDetector.Event
                if captureIsRecording {
                    event = self.audioInactivityDetector.startRecording(at: self.recordingDuration)
                } else {
                    if self.state == .recording {
                        // Capture stopped underneath us. Core flips
                        // isRecording before it resets systemAudioStatus,
                        // so the bridge mirror still holds the live value.
                        self.unexpectedCaptureStopEvidence = (
                            systemAudioStatus: self.capture.systemAudioStatus,
                            degradationWarning: self.systemAudioDegradationWarning
                        )
                        self.unheardSecondsAtCaptureStop = self.unheardPlaybackWarningStartedAt
                            .map { max(0, Date().timeIntervalSince($0)) }
                    }
                    event = self.audioInactivityDetector.stopRecording()
                    self.isMicBoostPromptVisible = false
                    self.audioRouteWarning = nil
                    self.systemAudioDegradationWarning = nil
                }
                self.applyAudioInactivityEvent(event)
            }
            .store(in: &cancellables)

        capture.$audioLevel
            .sink { [weak self] level in
                guard let self else { return }
                self.audioLevel = level
                self.latestMicLevel = level
                self.observeAudioActivity()
            }
            .store(in: &cancellables)

        capture.$systemLevel
            .sink { [weak self] level in
                guard let self else { return }
                self.systemLevel = level
                self.latestSystemLevel = level
                self.observeAudioActivity()
            }
            .store(in: &cancellables)

        capture.$recordingDuration
            .sink { [weak self] duration in
                guard let self else { return }
                // The capture timer ticks every 0.2s, but every @Published
                // mutation here re-renders any SwiftUI view observing this
                // controller (Home observes it directly). UI consumers only
                // display whole seconds, so republish the mirror on second
                // boundaries plus resets; diagnostics reads tolerate the
                // sub-second staleness. The inactivity tick below stays on
                // the raw 0.2s cadence.
                if Int(duration) != Int(self.recordingDuration) || duration < self.recordingDuration {
                    self.recordingDuration = duration
                }
                guard self.isRecording else { return }
                self.refreshSystemAudioSignalVerification(shouldWarn: duration >= 10)
                self.applyAudioInactivityEvent(
                    self.audioInactivityDetector.tick(at: duration)
                )
            }
            .store(in: &cancellables)

        capture.$micAttenuationCueObserved
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.handleMicAttenuationCue()
            }
            .store(in: &cancellables)

        capture.$routeStabilityWarningOutcome
            // Keep the nil reset in the deduplication stream. It separates
            // identical outcomes from consecutive recordings.
            .removeDuplicates()
            .compactMap { $0 }
            .sink { [weak self] outcome in
                self?.handleRouteStabilityWarning(outcome)
            }
            .store(in: &cancellables)

        capture.$systemAudioStatus
            .removeDuplicates()
            .sink { [weak self] status in
                guard let self else { return }
                self.systemAudioDegradationWarning = MeetingSystemAudioDegradationPolicy.next(
                    current: self.systemAudioDegradationWarning,
                    status: MeetingSystemAudioStatusCopy.caseValue(for: status),
                    isRecording: self.isRecording
                )
                self.refreshSystemAudioSignalVerification(shouldWarn: self.recordingDuration >= 10)
                let level: EventLevel = status.isWarning ? .warning : .info
                DiagnosticsTrail.record(
                    level: level,
                    engine: "meeting",
                    event: "system_audio_status_changed",
                    message: self.systemAudioStatusMessage(for: status),
                    context: self.baseDiagnosticsContext(
                        extra: [
                            "system_audio_status": status.diagnosticName,
                            "recording": self.boolString(self.isRecording),
                            "duration_ms": "\(Int(self.recordingDuration * 1000))"
                        ]
                    )
                )
            }
            .store(in: &cancellables)

        taskManager.$activeCount
            .combineLatest(taskManager.$speakerNamingRequest)
            .sink { [weak self] activeCount, speakerNamingRequest in
                guard let self else { return }
                if activeCount > 0 {
                    self.sttAdapter.beginTranscriptionJob()
                } else {
                    self.sttAdapter.finishTranscriptionJob()
                }
                self.transcriptionQueue.handleBackgroundTranscriptionWorkChanged(
                    snapshot: BackgroundTranscriptionWorkSnapshot(
                        activeCount: activeCount,
                        speakerNamingRequest: speakerNamingRequest
                    )
                )
            }
            .store(in: &cancellables)

        taskManager.$displayStatus
            .sink { [weak self] status in
                self?.updateDisplayStatus(status, source: .taskManagerMirror)
            }
            .store(in: &cancellables)

        taskManager.$lastSavedTranscriptURL
            .sink { [weak self] url in
                guard let self else { return }
                guard let url else {
                    self.savedTranscriptRestyleTask = nil
                    self.lastSavedTranscriptURL = nil
                    self.lastSavedTitle = nil
                    return
                }

                self.restyleSavedTranscriptInBackground(at: url)
            }
            .store(in: &cancellables)

        failedManager.$failedTranscriptions
            .sink { [weak self] failedTranscriptions in
                self?.refreshFailedMeetings(failedTranscriptions)
            }
            .store(in: &cancellables)

        sttRouter.$modelDownloadState
            .sink { [weak self] _ in
                self?.refreshWarmupStatus()
            }
            .store(in: &cancellables)

        diarization.$modelState
            .sink { [weak self] _ in
                self?.refreshWarmupStatus()
            }
            .store(in: &cancellables)

        refreshFailedMeetings()
        refreshWarmupStatus()
    }

    /// Restyling reads and rewrites the whole saved transcript and can rename
    /// the markdown + retained-audio artifacts, so it must stay off the main
    /// actor; multi-hour meetings produce multi-MB files. Restyles are chained
    /// so two passes never touch the same artifacts concurrently.
    private func restyleSavedTranscriptInBackground(at url: URL) {
        let previousRestyle = savedTranscriptRestyleTask
        let restyle = Task.detached(priority: .userInitiated) { () -> StyledMeetingTranscript in
            _ = await previousRestyle?.value
            let styled = MeetingTranscriptStyler.restyleTranscript(at: url)
            // Always-on cheap field extraction so the search index covers every
            // meeting, not just the heavy local-summary beta opt-in. Runs after
            // restyle (the body is now in canonical styled form) on this chained
            // background task, and is idempotent + frontmatter-only.
            if !styled.artifactPostProcessingBlocked {
                MeetingQuickSummaryWriter.ensureQuickSummary(at: styled.url)
            }
            return styled
        }
        savedTranscriptRestyleTask = restyle

        Task { @MainActor [weak self] in
            let styled = await restyle.value
            if let recoveryNotice = styled.artifactRecoveryNotice {
                self?.addArtifactRecoveryNotice(recoveryNotice)
                CaptureLibraryChangeBroadcaster.shared.noteArtifactsChanged(
                    transcriptURLs: [
                        recoveryNotice.sourceTranscriptURL,
                        recoveryNotice.targetTranscriptURL
                    ]
                )
                return
            }
            guard !styled.artifactPostProcessingBlocked else { return }
            let transcriptURL = styled.url
            // The restyle may have renamed the transcript + its audio/<stem>_audio
            // directory. Tell Home so any cached URLs for the old stem re-resolve.
            if styled.url != url {
                CaptureLibraryChangeBroadcaster.shared.noteArtifactsChanged(
                    transcriptURLs: [styled.url]
                )
            }
            Task.detached(priority: .utility) {
                let didChangeArtifacts = await MeetingAudioStorageManager
                    .processSavedTranscript(at: transcriptURL)
                // Recompression (WAV->M4A) and retention pruning rewrite the audio
                // paths Home cached at scan time; signal so the cache re-resolves.
                if didChangeArtifacts {
                    await MainActor.run {
                        CaptureLibraryChangeBroadcaster.shared.noteArtifactsChanged(
                            transcriptURLs: [transcriptURL]
                        )
                    }
                }
            }
            guard let self, self.savedTranscriptRestyleTask == restyle else { return }
            self.lastSavedTranscriptURL = styled.url
            self.lastSavedTitle = styled.title
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_transcript_artifact_ready",
                message: "Meeting transcript artifact is ready",
                context: self.baseDiagnosticsContext()
            )
        }
    }
}

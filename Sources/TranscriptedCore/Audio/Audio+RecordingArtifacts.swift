import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine
import Synchronization

// Stopped-recording finalization, journal abandon, artifact discard,
// system-audio URL publish/resolve, and the mic host fan-out flush.
extension Audio {
    struct StoppedMicRecordingFinalization {
        let micURL: URL?
        let disposition: RecordingStopFinalizationDisposition
    }

    // Existing internal fixture entry points now use the same artifact owner;
    // production Stop uses RecordingArtifactCompletion after its real drains.
    func retainStoppingJournalSession(_ session: MeetingRecordingJournalSession?, generation: UInt64) {
        _ = recordingArtifactOwner.retainCompatibilityStop(compatibilityArtifactContext(), generation: generation, token: session)
    }
    func finalizeStoppedMicRecordingResult(primaryURL: URL?, segments: [MicRecordingSegment],
                                          generation: UInt64) -> StoppedMicRecordingFinalization {
        guard let ticket = recordingArtifactOwner.ticket(forStopGeneration: generation) else {
            return StoppedMicRecordingFinalization(micURL: nil, disposition: .journalRecoveryOwned)
        }
        switch recordingArtifactOwner.claimQuiescentFinalization(ticket) {
        case .recovery:
            return StoppedMicRecordingFinalization(micURL: nil, disposition: .journalRecoveryOwned)
        case .normal, .normalThenDiscard:
            let finalURL = finalizeMicRecording(primaryURL: primaryURL, segments: segments)
            if case .normalRelease(let snapshot, _) = recordingArtifactOwner.normalFinalizationFinished(ticket, actualFinalMicURL: finalURL),
               let binding = snapshot.binding {
                recordingArtifactDispatcher.enqueue(.markFinalized(binding, finalMicURL: finalURL, endingSession: true))
            }
            return StoppedMicRecordingFinalization(micURL: finalURL, disposition: .finalized)
        case .notOwned:
            return StoppedMicRecordingFinalization(micURL: nil, disposition: .journalRecoveryOwned)
        }
    }

    /// Select recovery ownership once. The exact claim is released only after
    /// handed-off artifacts drain; a confirmed current discard cannot lose to
    /// expiry/pruning, and a later current discard cannot override recovery.
    @discardableResult
    public func abandonRecordingJournalFinalization(forStopGeneration generation: UInt64) -> Bool {
        if case .selected = recordingArtifactOwner.requestAbandon(stopGeneration: generation) { return true }
        return false
    }

    /// The caller selects its current context before suspension. Active files
    /// are deleted only after that context's producers/writers have settled.
    public func discardCurrentRecordingArtifacts(micAudioURL: URL?, systemAudioURL: URL?) {
        guard let context = recordingArtifactOwner.currentContext() else { return }
        // Standalone internal journal fixtures can build an already-quiescent
        // journal without ever starting capture (generation zero).
        if context.captureGeneration == 0, !isRecording, !isStarting,
           recordingArtifactOwner.ticket(for: context) == nil {
            _ = context.endpoint.discardCurrentRecordingArtifacts(micAudioURL: micAudioURL,
                systemAudioURL: systemAudioURL, allowedRoot: paths.audioCaptures)
            return
        }
        _ = recordingArtifactCompletion.requestDiscard(context: context)
    }

    /// A late generation-tagged callback has no access to the current journal;
    /// delete only its validated finalized files and matching on-disk journal.
    public func discardFinalizedRecordingArtifacts(micAudioURL: URL?, systemAudioURL: URL?) {
        MeetingRecordingJournalStore.discardRecordingArtifacts(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            allowedRoots: [paths.audioCaptures]
        )
    }

    /// Wait until every host callback already admitted from the meeting mic has
    /// run. The app uses this before finalizing borrowed-mic dictation, including
    /// when file finalization itself hit its outer timeout.
    public func flushMicHostPCMBufferFanout() async {
        await withCheckedContinuation { continuation in
            micHostPCMBufferFanout.flush {
                continuation.resume()
            }
        }
    }

    func assignSystemAudioFileURLIfCurrent(_ fileURL: URL, sessionGeneration: UInt64) {
        guard let context = artifactContext(for: sessionGeneration),
              recordingArtifactOwner.bindSystemCandidate(context, url: fileURL) else { return }
        systemAudioFileURL = fileURL
        restoreSystemAudioHealthyStatusAfterSuccessfulStart()
    }

    /// Bind the created WAV to its exact recording before main publication.
    func publishSystemAudioFileURLAtCreation(_ fileURL: URL, sessionGeneration: UInt64) {
        guard let context = artifactContext(for: sessionGeneration),
              recordingArtifactOwner.bindSystemCandidate(context, url: fileURL) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recordingSessionGeneration == sessionGeneration else { return }
            self.systemAudioFileURL = fileURL
            self.restoreSystemAudioHealthyStatusAfterSuccessfulStart()
        }
    }

    /// Stop-path system URL: ownership / journal / writer, not only the
    /// published property that can still be nil if main hasn't assigned it.
    /// A candidate whose file is already gone (a failed system start removes
    /// its WAV) resolves to nil so the meeting is not stamped as having a
    /// system track it never had.
    func resolvedSystemAudioFileURL(generation: UInt64) -> URL? {
        guard let url = resolvedSystemAudioFileURLCandidate(generation: generation) else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func resolvedSystemAudioFileURLCandidate(generation: UInt64) -> URL? {
        let context = artifactContext(for: generation)
        if let context, let url = recordingArtifactOwner.candidateSystemURL(in: context) { return url }
        if let url = systemAudioCaptureAttemptOwnership.fileURLOwned(by: generation) { return url }
        if let attempt = systemAudioCaptureAttemptOwnership.current,
           attempt.generation == generation, let writer = attempt.writer { return writer.url }
        if let context, let binding = recordingArtifactOwner.binding(in: context),
           let url = binding.endpoint.currentSystemAudioURL(session: binding.token) { return url }
        return recordingSessionGeneration == generation ? systemAudioFileURL : nil
    }
}

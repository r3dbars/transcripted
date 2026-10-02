import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine
import Synchronization

// Stopped-recording finalization, journal abandon, artifact discard,
// system-audio URL publish/resolve, and the mic host fan-out flush.
extension Audio {
    struct StoppingRecordingFinalization {
        let journalSession: MeetingRecordingJournalSession?
    }
    struct StoppedMicRecordingFinalization {
        let micURL: URL?
        let disposition: RecordingStopFinalizationDisposition
    }

    func retainStoppingJournalSession(
        _ session: MeetingRecordingJournalSession?,
        generation: UInt64
    ) {
        stoppingJournalSessionsLock.lock()
        stoppingRecordingFinalizations[generation] = StoppingRecordingFinalization(
            journalSession: session
        )
        stoppingJournalSessionsLock.unlock()
    }

    private func takeStoppingRecordingFinalization(
        generation: UInt64
    ) -> StoppingRecordingFinalization? {
        stoppingJournalSessionsLock.lock()
        defer { stoppingJournalSessionsLock.unlock() }
        return stoppingRecordingFinalizations.removeValue(forKey: generation)
    }

    /// Claims this generation's finalizer before it mutates any recording
    /// files. If recovery already took ownership, leave every segment and
    /// merged artifact untouched for that canonical recovery path.
    func finalizeStoppedMicRecordingResult(
        primaryURL: URL?,
        segments: [MicRecordingSegment],
        generation: UInt64
    ) -> StoppedMicRecordingFinalization {
        guard let finalization = takeStoppingRecordingFinalization(generation: generation) else {
            AppLogger.audioMic.info("Skipped abandoned mic finalization owned by recovery", [
                "stopGeneration": "\(generation)"
            ])
            return StoppedMicRecordingFinalization(
                micURL: nil,
                disposition: .journalRecoveryOwned
            )
        }
        let finalMicURL = finalizeMicRecording(primaryURL: primaryURL, segments: segments)
        recordingJournal.markFinalized(
            finalMicURL: finalMicURL,
            session: finalization.journalSession
        )
        return StoppedMicRecordingFinalization(
            micURL: finalMicURL,
            disposition: .finalized
        )
    }

    /// The host no longer retains a completion callback for this stopped
    /// generation. Atomically invalidate its journal session before releasing
    /// the live claim so recovery becomes the only remaining writer.
    @discardableResult
    public func abandonRecordingJournalFinalization(
        forStopGeneration generation: UInt64
    ) -> Bool {
        stoppingJournalSessionsLock.lock()
        guard let finalization = stoppingRecordingFinalizations.removeValue(forKey: generation) else {
            stoppingJournalSessionsLock.unlock()
            return false
        }
        if let session = finalization.journalSession {
            recordingJournal.abandonFinalization(session: session)
        }
        stoppingJournalSessionsLock.unlock()
        return true
    }

    /// Explicit discard owns the current journal's complete segment inventory,
    /// including the no-callback case where the returned URL tuple is empty.
    public func discardCurrentRecordingArtifacts(micAudioURL: URL?, systemAudioURL: URL?) {
        recordingJournal.discardCurrentRecordingArtifacts(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            allowedRoot: paths.audioCaptures
        )
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
        guard recordingSessionGeneration == sessionGeneration else { return }

        originalSystemAudioFileURL = fileURL
        systemAudioFileURL = fileURL
        recordingJournal.recordSystemAudio(fileURL, session: journalSession)
        restoreSystemAudioHealthyStatusAfterSuccessfulStart()
    }

    /// Journal + publish the system URL as soon as the WAV exists. Generation
    /// guarded like `assignSystemAudioFileURLIfCurrent`. The published
    /// assignment hops to main; the original/journal write happens now.
    func publishSystemAudioFileURLAtCreation(_ fileURL: URL, sessionGeneration: UInt64) {
        guard recordingSessionGeneration == sessionGeneration else { return }
        originalSystemAudioFileURL = fileURL
        recordingJournal.recordSystemAudio(fileURL, session: journalSession)
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
        if let url = originalSystemAudioFileURL { return url }
        if let url = systemAudioCaptureAttemptOwnership.fileURLOwned(by: generation) {
            return url
        }
        if let attempt = systemAudioCaptureAttemptOwnership.current,
           attempt.generation == generation,
           let writer = attempt.writer {
            return writer.url
        }
        if let url = recordingJournal.currentSystemAudioURL(session: journalSession) { return url }
        return systemAudioFileURL
    }
}

@preconcurrency import AVFoundation
import Foundation
import QuartzCore

/// The recovery segment a mic restart sized from its settled graph.
struct MicRecoverySegmentStart {
    let url: URL
    let writeContext: MicPCMWriteContext
}

/// The recovery segment step stopped this attempt and already logged why.
/// It ends the attempt without a retry, same as an early return.
struct MicRecoverySegmentAbandoned: Error {}

/// What one mic recovery attempt made, so its cleanup knows what to undo.
final class MicRecoverySegmentAttempt {
    var artifactAttempt: RecordingArtifactRecoveryAttempt<AVAudioFile>?
    var shouldKeep = false
}

/// Recovery segment setup and teardown for `recoverFromDeviceChange`.
extension Audio {

    /// Retires the current mic writer and creates the recovery segment, sized
    /// for `graph`, which is the settled route. Throws
    /// `MicRecoverySegmentAbandoned` when the attempt should end quietly.
    func createMicRecoverySegment(
        for graph: PreparedMeetingInputGraph,
        attempt: MicRecoverySegmentAttempt,
        usedInPlaceRestart: Bool,
        sessionGeneration: UInt64,
        switchStart: Date,
        lastMicBufferTime: inout TimeInterval
    ) throws -> MicRecoverySegmentStart {
        let recordingSnapshot = graph.recordingSnapshot
        refreshRealtimeAGCForCurrentProcessingMode(resetExisting: true)
        let oldChannelCount = self.inputChannelCount
        AppLogger.audioMic.info(
            usedInPlaceRestart
                ? "Restarting mic engine in place on pinned meeting input"
                : "Rebuilt mic engine on pinned meeting input",
            ["sampleRate": "\(recordingSnapshot.sampleRate)", "channels": "\(recordingSnapshot.channelCount)"]
        )

        // ALWAYS update channel count for proper downmix handling
        // This was a bug: if only channel count changed (not sample rate), downmix wouldn't work
        self.inputChannelCount = recordingSnapshot.channelCount
        if recordingSnapshot.channelCount > 1 && oldChannelCount != recordingSnapshot.channelCount {
            AppLogger.audioMic.debug("Recovery: will manually downmix to mono", ["channels": "\(recordingSnapshot.channelCount)"])
        }

        if oldChannelCount != recordingSnapshot.channelCount {
            AppLogger.audioMic.info("Input channel count changed during recovery", [
                "oldChannels": "\(oldChannelCount)",
                "newChannels": "\(recordingSnapshot.channelCount)"
            ])
        }

        AppLogger.audioMic.warning("Closing current mic file and creating recovery segment")
        guard let context = artifactContext(for: sessionGeneration) else { throw MicRecoverySegmentAbandoned() }
        let prepared: MicPCMWriteContext
        let fileURL: URL
        do {
            let monoFormat = try AudioRecordingFormatPolicy.makeMonoOutputFormat(sampleRate: recordingSnapshot.sampleRate)
            monoOutputFormat = monoFormat
            prepared = MicPCMWriteContext(generation: sessionGeneration, monoFormat: monoFormat,
                                          inputChannelCount: recordingSnapshot.channelCount)
            switch try micArtifactTransactions.createRecovery(context: context, prepared: prepared,
                afterRetirement: { retirement in
                    switch retirement {
                    case .retired: micRecoveryGapAnchor = lastMicBufferTime
                    case .alreadyRetired:
                        lastMicBufferTime = MicRecoveryGapAnchorPolicy.anchor(storedAnchor: micRecoveryGapAnchor,
                                                                             lastBufferTime: lastMicBufferTime)
                        AppLogger.audioMic.info("Previous mic recovery left no open segment; creating a new one")
                    }
                }, gapBefore: max(CACurrentMediaTime() - lastMicBufferTime, Date().timeIntervalSince(switchStart))) {
            case .registered(let registered, _):
                attempt.artifactAttempt = registered
                fileURL = registered.url
            case .notOwned: throw MicRecoverySegmentAbandoned()
            }
        } catch let abandoned as MicRecoverySegmentAbandoned {
            throw abandoned
        } catch MicArtifactTransactionFailure.stale {
            throw MicRecoverySegmentAbandoned()
        } catch {
            AppLogger.audioMic.error("Failed to create recovery audio file", ["error": error.localizedDescription])
            throw MicRecoverySegmentAbandoned()
        }
        let micWriteContext = prepared
        AppLogger.audioMic.info("Created recovery audio file", ["file": fileURL.lastPathComponent])

        guard sessionGeneration == recordingSessionGeneration else {
            AppLogger.audioMic.info("Skipping stale recovery before engine restart", [
                "expectedSession": "\(sessionGeneration)",
                "currentSession": "\(recordingSessionGeneration)"
            ])
            throw MicRecoverySegmentAbandoned()
        }
        return MicRecoverySegmentStart(url: fileURL, writeContext: micWriteContext)
    }

    /// Runs when a recovery attempt ends. Removes a segment the attempt did
    /// not keep, unless Stop already took it.
    func discardUnkeptMicRecoverySegment(
        _ attempt: MicRecoverySegmentAttempt,
        sessionGeneration: UInt64
    ) {
        guard let registered = attempt.artifactAttempt else { return }
        do { _ = try micArtifactTransactions.finishRecovery(attempt: registered, keep: attempt.shouldKeep) }
        catch {
            AppLogger.audioMic.warning("Could not finish recovery segment cleanup", ["error": error.localizedDescription])
        }
    }

    func logMicRecoveryGraphPrepareFailure(_ error: Error) {
        if error is AudioCaptureStaleSessionError { return }
        AppLogger.audioMic.error("Failed to prepare microphone recovery graph", [
            "error": error.localizedDescription
        ])
        logMicRecoveryWillRetry(stage: "prepare_graph")
    }

    /// The restart failed after the tap step began. Drops the tap and, for a
    /// reused in-place graph, schedules a fresh-graph retry right away.
    func failMicRecoveryRestart(
        _ error: Error,
        engine: AVAudioEngine,
        inputNode newInputNode: AVAudioInputNode,
        sessionGeneration: UInt64,
        reason: MicCaptureRestartReason,
        afterSystemWake: Bool,
        usedInPlaceRestart: Bool
    ) {
        if error is AudioCaptureStaleSessionError {
            AppLogger.audioMic.info("Skipping stale recovery restart", [
                "expectedSession": "\(sessionGeneration)",
                "currentSession": "\(recordingSessionGeneration)"
            ])
            return
        }
        AppLogger.audioMic.error("Failed to restart engine", ["error": error.localizedDescription])
        // The recovery segment is discarded when this attempt ends, so a slow mic that
        // starts delivering now would only feed a nil writer while
        // looking healthy to the watchdog. Stop it; the retry rebuilds.
        withAudioGraphLock {
            guard sessionGeneration == recordingSessionGeneration else { return }
            tearDownInputTapSafely(
                engine: engine,
                inputNode: newInputNode,
                operation: "device_recovery_no_audio"
            )
        }
        logMicRecoveryWillRetry(stage: "restart_engine")
        if usedInPlaceRestart {
            // The reused graph went stale. Build a fresh one right away
            // instead of waiting out the watchdog cooldown. Delayed a
            // beat so this attempt's ownership is released first.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.recoverFromDeviceChange(
                    sessionGeneration: sessionGeneration,
                    reason: reason,
                    afterSystemWake: afterSystemWake,
                    freshGraphRequested: true
                )
            }
        }
    }
}

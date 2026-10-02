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
    var url: URL?
    var writer: AVAudioFile?
    var writerWasInstalled = false
    var wasRegistered = false
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
        // Close explicitly so the retiring segment's WAV header is finalized
        // before the merger can ever read it. Even same-rate device switches
        // need a new segment so the missing-buffer interval can be padded.
        switch micAudioFileQueue.sync(execute: {
            micAudioFileOwnership.retireWriterForRecovery(by: sessionGeneration)
        }) {
        case .retired(let retiringWriter):
            retiringWriter.close()
            micRecoveryGapAnchor = lastMicBufferTime
        case .alreadyRetired:
            // An earlier attempt closed the last segment and then failed.
            // Its gap is still open; this attempt's segment pads all of it,
            // from the last frame that segment kept. Frames a failed attempt
            // wrote were deleted with its segment, so they don't count.
            lastMicBufferTime = MicRecoveryGapAnchorPolicy.anchor(
                storedAnchor: micRecoveryGapAnchor,
                lastBufferTime: lastMicBufferTime
            )
            AppLogger.audioMic.info("Previous mic recovery left no open segment; creating a new one")
        case .notOwned:
            AppLogger.audioMic.info("Skipping recovery because mic writer ownership changed", [
                "expectedSession": "\(sessionGeneration)",
                "currentSession": "\(recordingSessionGeneration)"
            ])
            throw MicRecoverySegmentAbandoned()
        }

        let captureDir = self.paths.audioCaptures
        try? FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
        let timestamp = DateFormattingHelper.formatFilenamePrecise(Date())
        let fileURL = captureDir.appendingPathComponent("meeting_\(timestamp)_mic_recovery.wav")
        attempt.url = fileURL

        let micWriteContext: MicPCMWriteContext
        do {
            let monoFormat = try AudioRecordingFormatPolicy.makeMonoOutputFormat(
                sampleRate: recordingSnapshot.sampleRate
            )
            self.monoOutputFormat = monoFormat
            micWriteContext = MicPCMWriteContext(
                generation: sessionGeneration,
                monoFormat: monoFormat,
                inputChannelCount: recordingSnapshot.channelCount
            )

            let newFile = try AVAudioFile(
                forWriting: fileURL,
                settings: monoFormat.settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
            FileManager.default.restrictToOwnerOnly(atPath: fileURL.path)
            attempt.writer = newFile
            let installed = micAudioFileQueue.sync {
                micAudioFileOwnership.installRecoveryWriter(
                    newFile,
                    generation: sessionGeneration
                )
            }
            guard installed else {
                AppLogger.audioMic.info("Skipping stale recovery writer replacement", [
                    "expectedSession": "\(sessionGeneration)",
                    "currentSession": "\(recordingSessionGeneration)"
                ])
                throw MicRecoverySegmentAbandoned()
            }
            attempt.writerWasInstalled = true
            // List the segment with the recording before any buffer can
            // reach it, so a Stop during the restart keeps its audio instead
            // of deleting it. The gap is corrected once the first frame lands.
            guard registerMicRecoverySegment(
                MicRecordingSegment(
                    url: fileURL,
                    gapBeforeDuration: max(
                        CACurrentMediaTime() - lastMicBufferTime,
                        Date().timeIntervalSince(switchStart)
                    )
                ),
                sessionGeneration: sessionGeneration
            ) else {
                AppLogger.audioMic.info("Skipping stale recovery before segment registration", [
                    "expectedSession": "\(sessionGeneration)",
                    "currentSession": "\(recordingSessionGeneration)"
                ])
                throw MicRecoverySegmentAbandoned()
            }
            attempt.wasRegistered = true
            AppLogger.audioMic.info("Created recovery audio file", ["file": fileURL.lastPathComponent])
        } catch let abandoned as MicRecoverySegmentAbandoned {
            throw abandoned
        } catch {
            AppLogger.audioMic.error("Failed to create recovery audio file", ["error": error.localizedDescription])
            throw MicRecoverySegmentAbandoned()
        }

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
        guard let url = attempt.url, !attempt.shouldKeep else { return }
        if attempt.wasRegistered,
           !unregisterMicRecoverySegment(url, sessionGeneration: sessionGeneration) {
            // Stop landed after the segment was registered. It already
            // listed, closed and will merge this file, including any
            // audio that arrived before the tap came down.
            AppLogger.audioMic.info("Stop took the in-progress recovery segment", [
                "file": url.lastPathComponent
            ])
            return
        }
        if let writer = attempt.writer {
            let shouldCloseWriter = !attempt.writerWasInstalled || micAudioFileQueue.sync {
                micAudioFileOwnership.removeIfOwned(
                    writer,
                    generation: sessionGeneration
                )
            }
            if shouldCloseWriter {
                writer.close()
            }
        }
        try? FileManager.default.removeItem(at: url)
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

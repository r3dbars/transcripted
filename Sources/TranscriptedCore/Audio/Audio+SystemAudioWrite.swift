import Foundation
import Darwin
@preconcurrency import AVFoundation

extension Audio {

    @discardableResult
    func recordSystemWriteFailure(
        _ error: Error,
        generation: UInt64? = nil,
        bufferNumber: Int? = nil
    ) -> Bool {
        let generation = generation ?? recordingSessionGeneration
        guard let count = incrementSystemWriteError(generation: generation) else {
            return false
        }
        if count <= 3 || count == maxConsecutiveWriteErrors {
            var context = [
                "error": error.localizedDescription,
                "consecutive": "\(count)"
            ]
            if let bufferNumber {
                context["bufferNumber"] = "\(bufferNumber)"
            }
            AppLogger.audioSystem.error("System audio write failed", context)
        }
        guard count >= maxConsecutiveWriteErrors else { return false }
        AppLogger.audioSystem.error("Too many consecutive system write errors, keeping microphone recording")
        surfaceSystemWriteFailureAndStop(generation: generation)
        return true
    }

    private func surfaceSystemWriteFailureAndStop(generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.recordingSessionGeneration == generation,
                  self.isRecording else { return }
            self.failSystemAudioKeepMic(generation: generation)
            self.error = "System audio couldn't be saved to disk. Microphone recording continues. Check that there's free space and the save location is still available."
        }
    }

    private static let maxSystemRecoverySilencePadSeconds: TimeInterval = 180
    private static let systemRecoverySilencePadChunkSeconds: TimeInterval = 1

    /// Writes a bounded silence pad into the current system writer on the
    /// file queue. Called after confirmed SCK recovery, before new buffers
    /// are accepted (writes are held until this returns).
    func writeSystemRecoverySilencePad(duration: TimeInterval, generation: UInt64) {
        systemAudioFileQueue.sync {
            self.writeSystemRecoverySilencePadOnFileQueue(duration: duration, generation: generation)
        }
    }

    /// Queues the pad behind the buffers already written and ahead of any
    /// buffer the capture hands over after this call returns. Lets the
    /// capture's own thread release the write-hold before its first new
    /// buffer, without waiting for the disk.
    func enqueueSystemRecoverySilencePad(duration: TimeInterval, generation: UInt64) {
        systemAudioFileQueue.async { [weak self] in
            self?.writeSystemRecoverySilencePadOnFileQueue(duration: duration, generation: generation)
        }
    }

    private func writeSystemRecoverySilencePadOnFileQueue(duration: TimeInterval, generation: UInt64) {
        let capped = min(max(0, duration), Self.maxSystemRecoverySilencePadSeconds)
        guard capped > 0 else { return }
        do {
            guard let attempt = self.systemAudioCaptureAttemptOwnership.current,
                  attempt.generation == generation,
                  let writer = attempt.writer else { return }
            let format = writer.processingFormat
            let sampleRate = format.sampleRate
            guard sampleRate > 0, format.channelCount > 0 else { return }
            var remaining = AVAudioFrameCount((capped * sampleRate).rounded())
            let chunkFrames = AVAudioFrameCount(
                max(1, (Self.systemRecoverySilencePadChunkSeconds * sampleRate).rounded())
            )
            while remaining > 0 {
                let frames = min(remaining, chunkFrames)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                    break
                }
                buffer.frameLength = frames
                if let channels = buffer.floatChannelData {
                    let channelCount = format.isInterleaved ? 1 : Int(format.channelCount)
                    let samplesPerChannel = format.isInterleaved
                        ? Int(frames) * Int(format.channelCount)
                        : Int(frames)
                    for channel in 0..<channelCount {
                        memset(channels[channel], 0, samplesPerChannel * MemoryLayout<Float>.size)
                    }
                }
                do {
                    try writer.write(from: buffer)
                    self.recordSystemWriteSuccess(generation: generation)
                } catch {
                    AppLogger.audioSystem.warning("Failed to write system recovery silence pad", [
                        "error": error.localizedDescription
                    ])
                    break
                }
                remaining -= frames
            }
        }
    }

    /// Marks system audio failed and tears down SCK + the system writer
    /// without stopping the microphone — the same mic-only policy as a
    /// system-audio start failure.
    private func failSystemAudioKeepMic(generation: UInt64) {
        systemAudioFailed = true
        systemAudioStatus = .failed
        let captureAttempt = systemAudioCaptureAttemptOwnership.captureOwned(
            by: generation
        )
        systemAudioSetupQueue.async {
            captureAttempt?.cancel()
        }
        systemAudioFileQueue.async { [weak self] in
            guard let self else { return }
            guard let captureAttempt else { return }
            let writer = self.systemAudioCaptureAttemptOwnership.takeWriterOwned(
                by: generation,
                capture: captureAttempt
            )
            writer?.close()
            self.endSystemWriteErrorTracking(generation: generation)
        }
    }

    func surfaceSystemWriteBackpressureAndStop(generation: UInt64) {
        guard writeBackpressureStopAdmission.claim(generation: generation) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.recordingSessionGeneration == generation,
                  self.isRecording else { return }
            self.systemAudioFailed = true
            self.systemAudioStatus = .failed
            self.error = "Recording stopped \u{2014} Transcripted couldn't keep up while saving system audio. Your partial recording is preserved. Check the save location, then start a new recording."
            self.stop()
        }
    }

    // MARK: - System Audio Status

    /// Records a system-audio start failure while the meeting is still in the
    /// asynchronous start phase. The normal error-message status helper
    /// intentionally collapses non-recording state to .unknown, which is
    /// correct after stop but loses the start-failure discriminator here.
    func recordSystemAudioStartFailure() {
        recordStartFailureStage(.systemAudio)
        systemAudioStatus = .failed
        systemAudioFailed = true
    }

    /// Updates systemAudioStatus based on the system-audio backend's error messages
    func updateSystemAudioStatus(fromError errorMessage: String?) {
        // A mic-only recording has no tap of its own. A late message from the
        // previous meeting's tap must not mark it failed or reconnecting.
        guard isRecording, currentRecordingCapturesSystemAudio else {
            systemAudioStatus = .unknown
            return
        }

        if let message = errorMessage {
            let normalizedMessage = message.lowercased()
            // A terminal message can mention reconnecting ("...no audio
            // buffers after reconnecting"), so failure wins. Classifying it
            // as reconnecting hid a dead tap behind a status that never ends.
            if normalizedMessage.contains("system audio failed") {
                systemAudioStatus = .failed
                systemAudioFailed = true
            } else if normalizedMessage.contains("reconnecting") {
                // ScreenCaptureKit owns the bounded restart and clears this
                // state by publishing nil after the replacement stream starts.
                systemAudioStatus = .reconnecting
            } else if message.contains("Switched to") {
                // Brief reconnecting state, then back to healthy
                systemAudioStatus = .reconnecting
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, self.isRecording else { return }
                    if self.systemAudioStatus == .reconnecting {
                        self.systemAudioStatus = .healthy
                    }
                }
            } else if normalizedMessage.contains("unavailable") || normalizedMessage.contains("failed") {
                systemAudioStatus = .failed
                systemAudioFailed = true
            }
        } else {
            // No error - status is healthy (if we're recording)
            if systemAudioStatus != .silent {
                systemAudioStatus = .healthy
            }
        }
    }
}

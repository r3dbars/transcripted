import Foundation
@preconcurrency import AVFoundation
import QuartzCore

/// Immutable file-write state captured when a mic tap is installed.
///
/// A successor recording may publish a different channel count and mono format
/// while the previous generation's bounded tail is still draining. Keeping the
/// exact tap generation and format in every queued block prevents that old tail
/// from reading successor state.
struct MicPCMWriteContext: @unchecked Sendable {
    let generation: UInt64
    let monoFormat: AVAudioFormat
    let inputChannelCount: AVAudioChannelCount
}

extension Audio {

    // MARK: - Mic Buffer Write

    /// Shared mic buffer handler used by both initial tap (startAudioCapture) and recovery tap (recoverFromDeviceChange).
    /// Dispatches mono downmix + file write to micAudioFileQueue.
    ///
    /// When `realtimeAGC` is non-nil (i.e. VPIO is off — the default), gain
    /// is applied to the deep-copied buffer before it reaches the live-
    /// preview consumer and the file write. The level meter intentionally
    /// reads the raw (pre-AGC) buffer so the meter shows actual mic
    /// activity and the silence/inactivity detector still fires when the
    /// room is genuinely quiet. (AGC would otherwise amplify ambient noise
    /// up to "speech-looking" levels and defeat the inactivity prompt.)
    func handleMicBuffer(_ buffer: AVAudioPCMBuffer, writeContext: MicPCMWriteContext) {
        let sessionGeneration = writeContext.generation
        guard sessionGeneration == recordingSessionGeneration else {
            handleMicStopTailBuffer(buffer, writeContext: writeContext)
            return
        }
        // Empty callbacks do not prove the input route can deliver audio. Let
        // the start gate and watchdog keep waiting for a real mic frame.
        guard buffer.frameLength > 0 else { return }

        micBufferCount += 1
        if MicWatchdogArmingPolicy.shouldArm(
            afterNonemptyBufferCount: micBufferCount
        ) {
            markMicAudioStreamingIfCurrent(sessionGeneration: sessionGeneration)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.recordingSessionGeneration == sessionGeneration,
                      self.isRecording else { return }
                self.startWatchdog()
            }
        }
        lastBufferTime = CACurrentMediaTime()
        let rawPeak = linearPeak(buffer: buffer)

        // Meter + silence detection see the RAW signal so the user's
        // visible level reflects their actual mic input, and the
        // "Still recording?" prompt still triggers in a quiet room.
        calculateLevel(buffer: buffer)

        // The tap-callback buffer is borrowed memory; modify a copy so the
        // CoreAudio-owned original stays untouched. The copy is what the
        // STT consumer callback and the file write see, both of which
        // benefit from AGC's normalized loudness.
        guard let bufferForAsyncUse = deepCopyBuffer(buffer) else {
            AppLogger.audioMic.warning("Failed to copy mic buffer for async write")
            recordMicSignalPeaks(raw: rawPeak, processed: 0, appliedGain: nil, agcMaxGain: nil)
            return
        }

        // Apply real-time AGC to the working copy. No-op when VPIO is on
        // (`agc == nil` records nil gain so the attenuation detector stays
        // dormant). `appliedGain` is read on the same thread that calls
        // process() — the only cross-call read — preserving RealtimeAGC's
        // lock-free single-thread contract.
        let agc = realtimeAGC
        agc?.process(buffer: bufferForAsyncUse)
        recordMicSignalPeaks(
            raw: rawPeak,
            processed: linearPeak(buffer: bufferForAsyncUse),
            appliedGain: agc?.appliedGain,
            agcMaxGain: agc?.maxGain
        )

        let retainedBytes = PCMBufferBackpressureGate.retainedByteCount(for: bufferForAsyncUse)
        switch micAudioWriteBackpressure.admit(
            bytes: retainedBytes,
            generation: sessionGeneration
        ) {
        case .accepted:
            break
        case .firstOverflow:
            AppLogger.audioMic.error("Mic audio write backlog exceeded memory limit", [
                "limitBytes": "\(micAudioWriteBackpressure.byteLimit)"
            ])
            surfaceMicWriteBackpressureAndStop(generation: sessionGeneration)
            return
        case .closed:
            return
        }

        if let hostHandler = onMicPCMBuffer {
            switch micHostPCMBufferFanout.enqueue(
                bufferForAsyncUse,
                generation: sessionGeneration,
                handler: hostHandler
            ) {
            case .accepted:
                break
            case .firstOverflow:
                AppLogger.audioMic.error("Mic host fan-out backlog exceeded memory limit", [
                    "limitBytes": "\(micHostPCMBufferFanout.byteLimit)"
                ])
                surfaceMicWriteBackpressureAndStop(generation: sessionGeneration)
            case .closed:
                break
            }
        }

        enqueueMicFileWrite(
            bufferForAsyncUse,
            retainedBytes: retainedBytes,
            writeContext: writeContext
        )
    }

    /// `Audio.stop()` advances the recording generation right away, but the
    /// input tap is torn down later on a background queue, and until then it
    /// keeps delivering audio the user spoke just before pressing Stop. Stop
    /// holds this generation's write admission in `finishing` until the tap is
    /// gone, so those buffers still reach this recording's file. The meter,
    /// watchdog, and live host consumer are skipped: the session they report
    /// on has already ended.
    func handleMicStopTailBuffer(_ buffer: AVAudioPCMBuffer, writeContext: MicPCMWriteContext) {
        let sessionGeneration = writeContext.generation
        guard buffer.frameLength > 0,
              micAudioWriteBackpressure.isFinishing(generation: sessionGeneration),
              let bufferForAsyncUse = deepCopyBuffer(buffer) else { return }

        // Same tap thread as the rest of this recording, so RealtimeAGC's
        // single-thread contract holds and the tail keeps the same loudness.
        realtimeAGC?.process(buffer: bufferForAsyncUse)

        let retainedBytes = PCMBufferBackpressureGate.retainedByteCount(for: bufferForAsyncUse)
        guard micAudioWriteBackpressure.admit(
            bytes: retainedBytes,
            generation: sessionGeneration
        ) == .accepted else { return }

        enqueueMicFileWrite(
            bufferForAsyncUse,
            retainedBytes: retainedBytes,
            writeContext: writeContext
        )
    }

    /// Writes one admitted mic buffer on `micAudioFileQueue`. The caller has
    /// already reserved `retainedBytes`; this releases them once the write ends.
    private func enqueueMicFileWrite(
        _ bufferForAsyncUse: AVAudioPCMBuffer,
        retainedBytes: Int,
        writeContext: MicPCMWriteContext
    ) {
        let sessionGeneration = writeContext.generation
        let backpressure = micAudioWriteBackpressure
        let monoFormat = writeContext.monoFormat
        let inputChannelCount = writeContext.inputChannelCount
        micAudioFileQueue.async { [weak self] in
            defer { backpressure.release(bytes: retainedBytes) }
            guard let self,
                  let writeErrorCount = self.micWriteErrorCount(
                    generation: sessionGeneration
                  ),
                  writeErrorCount < self.maxConsecutiveWriteErrors,
                  let audioFile = self.micAudioFileOwnership.writerOwned(
                    by: sessionGeneration
                  ) else { return }

            do {
                if inputChannelCount > 1 {
                    guard let monoBuffer = self.manualDownmix(buffer: bufferForAsyncUse, to: monoFormat) else {
                        AppLogger.audioMic.error("Failed to downmix buffer")
                        return
                    }
                    try audioFile.write(from: monoBuffer)
                } else {
                    try audioFile.write(from: bufferForAsyncUse)
                }
                self.recordMicWriteSuccess(generation: sessionGeneration)
            } catch {
                self.recordMicWriteFailure(error, generation: sessionGeneration)
            }
        }
    }

    /// Records one mic file-write failure. Bumps the consecutive-error counter,
    /// logs (rate-limited to the first few and the cap), and — when the cap is
    /// reached — stops the recording and surfaces the error. Once the cap is hit
    /// the writer drops every later buffer (the guard at the top of the
    /// `micAudioFileQueue` block in `enqueueMicFileWrite`), so without this terminal
    /// stop the recording keeps reporting `isRecording == true` and the duration
    /// timer keeps counting while no mic audio is being saved. The common
    /// full-disk cause is already caught by the 30s disk-space check in
    /// `startTimer()`; this covers the non-disk-full stalls (permission/sandbox
    /// loss, file deleted under the handle). Returns true when this failure
    /// tripped the cap. Runs on `micAudioFileQueue`.
    @discardableResult
    func recordMicWriteFailure(
        _ error: Error,
        generation: UInt64? = nil
    ) -> Bool {
        let generation = generation ?? recordingSessionGeneration
        guard let count = incrementMicWriteError(generation: generation) else {
            return false
        }
        if count <= 3 || count == maxConsecutiveWriteErrors {
            AppLogger.audioMic.error("Write failed", ["error": error.localizedDescription, "consecutive": "\(count)"])
        }
        guard count >= maxConsecutiveWriteErrors else { return false }
        AppLogger.audioMic.error("Too many consecutive write errors, stopping mic writes")
        surfaceWriteFailureAndStop(generation: generation)
        return true
    }

    /// Stops the recording and surfaces a write-failure error, mirroring the
    /// disk-full stop path in `startTimer()`. Callers run on a file-write queue,
    /// so this hops to main. No-ops if recording already ended (a cap crossed
    /// during teardown), so it can't double-stop. The user sees a stopped
    /// recording with a clear reason instead of a dead one that still looks
    /// alive.
    func surfaceWriteFailureAndStop(generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.recordingSessionGeneration == generation,
                  self.isRecording else { return }
            self.error = "Recording stopped \u{2014} Transcripted couldn't save audio to disk. Check that there's free space and the save location is still available, then start a new recording."
            self.stop()
        }
    }

    func surfaceMicWriteBackpressureAndStop(generation: UInt64) {
        guard writeBackpressureStopAdmission.claim(generation: generation) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.recordingSessionGeneration == generation,
                  self.isRecording else { return }
            self.error = "Recording stopped \u{2014} Transcripted couldn't keep up while saving microphone audio. Your partial recording is preserved. Check the save location, then start a new recording."
            self.stop()
        }
    }

    func finalizeMicRecording(primaryURL: URL?, segments: [MicRecordingSegment]) -> URL? {
        guard let primaryURL else { return segments.last?.url }
        guard segments.count > 1 else { return primaryURL }

        let mergeStart = Date()
        do {
            let outcome = try MicRecordingFileMerger.merge(primaryURL: primaryURL, segments: segments)
            let insertedSilenceSamples = segments
                .dropFirst()
                .reduce(0) { partialResult, segment in
                    partialResult + MicRecordingMergePlan.silenceSampleCount(before: segment, sampleRate: 16_000)
                }
            let context: [String: String] = [
                "segments": "\(outcome.segmentCount)",
                "appended": "\(outcome.appendedSegments)",
                "skipped": "\(outcome.skippedSegments)",
                "repaired": "\(outcome.repairedSegments)",
                "padded": "\(outcome.paddedSegments)",
                "durationSeconds": String(format: "%.2f", Date().timeIntervalSince(mergeStart)),
                "insertedSilenceSeconds": String(format: "%.3f", Double(insertedSilenceSamples) / 16_000),
                "file": outcome.url?.lastPathComponent ?? primaryURL.lastPathComponent
            ]
            if outcome.isFullFidelity {
                AppLogger.audioMic.info("Merged mic recovery segments", context)
            } else {
                // Some recorded audio is missing from the merged file; the
                // source segments stay on disk for recovery.
                AppLogger.audioMic.error("Merged mic recovery segments with degraded fidelity", context)
            }
            return outcome.url
        } catch {
            AppLogger.audioMic.error("Failed to merge mic recovery segments", [
                "segments": "\(segments.count)",
                "durationSeconds": String(format: "%.2f", Date().timeIntervalSince(mergeStart)),
                "error": error.localizedDescription
            ])
            return primaryURL
        }
    }
}

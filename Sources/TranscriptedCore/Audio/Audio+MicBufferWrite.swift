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
    let muteTimeline: MeetingMicMuteTimeline
    var continuity = MicCaptureContinuity()
    let monoFormat: AVAudioFormat
    let inputChannelCount: AVAudioChannelCount

    func forNewTap(start: Double = PinnedMicrophoneBufferRing.hostSecondsNow()) -> Self {
        var context = self
        context.continuity = MicCaptureContinuity(start: start)
        return context
    }
}

enum MicCaptureTiming {
    case native(hostSeconds: Double, received: Double = PinnedMicrophoneBufferRing.hostSecondsNow())
    case redactedBeforeConversion(rawPeak: Float)

    func redact(_ buffer: AVAudioPCMBuffer, using context: MicPCMWriteContext) {
        if case let .native(seconds, received) = self {
            context.muteTimeline.redact(buffer, hostSeconds: seconds, received: received, continuity: context.continuity)
        }
    }

    init(_ time: AVAudioTime) {
        let stamp = time.audioTimeStamp
        self = .native(hostSeconds: stamp.mFlags.contains(.hostTimeValid)
            ? Double(stamp.mHostTime) * PinnedMicrophoneBufferRing.secondsPerHostTick : 0)
    }
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
    func handleMicBuffer(_ buffer: AVAudioPCMBuffer, timing: MicCaptureTiming, writeContext: MicPCMWriteContext) {
        let sessionGeneration = writeContext.generation
        guard sessionGeneration == recordingSessionGeneration else {
            handleMicStopTailBuffer(buffer, timing: timing, writeContext: writeContext)
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
        let rawPeak: Float
        switch timing {
        case .native:
            rawPeak = linearPeak(buffer: buffer)
            calculateLevel(buffer: buffer)
        case let .redactedBeforeConversion(peak):
            rawPeak = peak
        }
        if let window = micCaptureTelemetry.record(buffer, arrival: CACurrentMediaTime()) {
            AppLogger.audioMic.info("Mic capture window", window)
        }

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

        // Explicit mic mute silences every consumer of this meeting input,
        // including a borrowed dictation. Reuse the owned copy so mute adds
        // no buffer allocation. Dictation alone gates just the meeting track.
        let meetingBuffer: AVAudioPCMBuffer
        timing.redact(bufferForAsyncUse, using: writeContext)
        if isMicGatedForBorrowedDictation {
            guard let silent = silentCopy(matching: bufferForAsyncUse) else {
                AppLogger.audioMic.warning("Failed to build silent mic buffer while dictation is borrowing the mic")
                return
            }
            meetingBuffer = silent
        } else {
            meetingBuffer = bufferForAsyncUse
        }

        let retainedBytes = PCMBufferBackpressureGate.retainedByteCount(for: meetingBuffer)
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

        if let liveHandler = onLivePCMBuffer {
            livePCMDelivery.enqueue(meetingBuffer, source: .microphone, captureGeneration: sessionGeneration, handler: liveHandler)
        }

        enqueueMicFileWrite(
            meetingBuffer,
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
    private func handleMicStopTailBuffer(_ buffer: AVAudioPCMBuffer, timing: MicCaptureTiming, writeContext: MicPCMWriteContext) {
        let sessionGeneration = writeContext.generation
        guard buffer.frameLength > 0,
              micAudioWriteBackpressure.isFinishing(generation: sessionGeneration),
              let bufferForAsyncUse = deepCopyBuffer(buffer) else { return }

        // Same tap thread as the rest of this recording, so RealtimeAGC's
        // single-thread contract holds and the tail keeps the same loudness.
        realtimeAGC?.process(buffer: bufferForAsyncUse)
        // No host consumer sees the tail, so a gated tail is just silence.
        timing.redact(bufferForAsyncUse, using: writeContext)
        if isMicGatedForBorrowedDictation {
            zeroSamples(of: bufferForAsyncUse)
        }

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

            let bufferFormat = bufferForAsyncUse.format
            let fileFormat = audioFile.processingFormat
            switch MicWriteFormatPolicy.decision(
                bufferSampleRate: bufferFormat.sampleRate,
                bufferChannelCount: bufferFormat.channelCount,
                tapSampleRate: monoFormat.sampleRate,
                tapChannelCount: inputChannelCount,
                fileSampleRate: fileFormat.sampleRate,
                fileChannelCount: fileFormat.channelCount
            ) {
            case .dropStale:
                // Recovery already replaced the writer. An in-flight buffer
                // from the old tap cannot go in the new file.
                return
            case .recover:
                self.recoverFromMicFormatMismatch(generation: sessionGeneration)
                return
            case .write:
                break
            }

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
                // Format/rate changes can still throw from write (-50 / 'fmt?')
                // when a field the policy did not compare moved. Recover the
                // tap instead of counting that toward the fatal write cap.
                if MicWriteFormatPolicy.isFormatMismatchError(error) {
                    self.recoverFromMicFormatMismatch(generation: sessionGeneration)
                    return
                }
                self.recordMicWriteFailure(error, generation: sessionGeneration)
            }
        }
    }

    /// Restarts the mic onto a new segment because the live tap's format no
    /// longer matches the recording file. Must not run on `micAudioFileQueue`:
    /// `recoverFromDeviceChange` waits on that queue. A test handler stands
    /// in so AudioTests never build an engine or touch `inputNode` (AirPods
    /// as the default input would flip into call mode).
    func recoverFromMicFormatMismatch(generation: UInt64) {
        recordMicWriteSuccess(generation: generation)
        if let handler = micFormatRecoveryHandlerForTesting {
            handler(generation)
            return
        }
        guard !isMicRecovering else { return }
        guard recoveryAttemptCount < maxRecoveryAttempts else {
            AppLogger.audioMic.warning(
                "Mic write format mismatch after recovery budget spent; dropping the buffer and leaving the mic to the watchdog"
            )
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            AppLogger.audioMic.warning(
                "Mic write format no longer matches the recording file; recovering onto a new segment"
            )
            self.recoverFromDeviceChange(sessionGeneration: generation)
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
        // A format-mismatch recovery is already swapping the writer. Errors
        // from the outgoing tap must not trip the cap and end the meeting.
        guard !isMicRecovering else { return false }
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
    private func surfaceWriteFailureAndStop(generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.recordingSessionGeneration == generation,
                  self.isRecording else { return }
            self.error = "Recording stopped \u{2014} Transcripted couldn't save audio to disk. Check that there's free space and the save location is still available, then start a new recording."
            self.internalStopCause = .micWriteFailed
            self.stop()
        }
    }

    private func surfaceMicWriteBackpressureAndStop(generation: UInt64) {
        guard writeBackpressureStopAdmission.claim(generation: generation) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.recordingSessionGeneration == generation,
                  self.isRecording else { return }
            self.error = "Recording stopped \u{2014} Transcripted couldn't keep up while saving microphone audio. Your partial recording is preserved. Check the save location, then start a new recording."
            self.internalStopCause = .micWriteBackpressure
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

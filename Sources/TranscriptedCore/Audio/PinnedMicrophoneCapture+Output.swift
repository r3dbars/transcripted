import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import Synchronization

extension PinnedMicrophoneCapture {
    func emit(_ event: PinnedMicrophoneCaptureEvent) {
        eventHandler?(event)
    }

    /// Hands `item` to the owner now when nothing waits ahead of it, else
    /// queues it behind the pending pad so order is kept. Silence is always
    /// queued: it is only ever delivered by `flushPendingOutput`, paced.
    private func deliverInOrder(_ item: PendingOutput) {
        guard pendingOutput.isEmpty else {
            pendingOutput.append(item)
            return
        }
        switch item {
        case let .audio(buffer):
            callback?(buffer)
        case let .event(event):
            emit(event)
        case .silence:
            pendingOutput.append(item)
        }
    }

    func deliver(_ buffer: AVAudioPCMBuffer, hostSeconds: TimeInterval) {
        let deliveryGeneration = generation
        if hostSeconds > 0 {
            if let expected = expectedNextHostSeconds {
                let hole = hostSeconds - expected
                if hole > Self.gapThresholdSeconds {
                    scheduleGap(seconds: hole)
                    guard generation == deliveryGeneration, callback != nil else { return }
                }
            }
            let rate = buffer.format.sampleRate
            expectedNextHostSeconds = hostSeconds + (rate > 0 ? Double(buffer.frameLength) / rate : 0)
        } else {
            // No timestamp: never measure the next hole from a stale one.
            expectedNextHostSeconds = nil
        }
        if let converted = convertToRecordingFormat(buffer) { deliverInOrder(.audio(converted)) }
        guard generation == deliveryGeneration else { return }
        trackSilentInput(buffer)
    }

    /// Reports the hole and queues its silence. The silence goes out paced by
    /// `flushPendingOutput`, always ahead of the buffer that revealed the hole.
    private func scheduleGap(seconds: TimeInterval) {
        let gapGeneration = generation
        var paddedFrames = 0
        var paddedSeconds: TimeInterval = 0
        if configuration.padsGapsWithSilence, let format, format.sampleRate > 0 {
            let target = min(seconds, configuration.maxSilencePadSeconds)
            if target.isFinite, target > 0 {
                paddedFrames = Int((target * format.sampleRate).rounded())
                paddedSeconds = Double(paddedFrames) / format.sampleRate
            }
        }
        gapCount += 1
        deliverInOrder(.event(.gap(seconds: seconds, paddedSeconds: paddedSeconds)))
        guard generation == gapGeneration, paddedFrames > 0 else { return }
        pendingOutput.append(.silence(frames: paddedFrames))
    }

    /// Delivers queued output in order. Silence is limited to
    /// `padFrameBudget` frames per call; when the budget runs out mid-pad the
    /// rest waits for the next tick, or is dropped when
    /// `dropsSilenceOverBudget` (finishing: keep the tail audio, not the pad).
    func flushPendingOutput(padFrameBudget: Int, dropsSilenceOverBudget: Bool) {
        let flushGeneration = generation
        var budget = padFrameBudget
        while let item = pendingOutput.first {
            switch item {
            case let .audio(buffer):
                pendingOutput.removeFirst()
                callback?(buffer)
            case let .event(event):
                pendingOutput.removeFirst()
                emit(event)
            case let .silence(frames):
                let wanted = min(frames, max(0, budget))
                let delivered = wanted > 0 ? deliverSilence(frames: wanted) : 0
                // The owner stopped the capture from inside a callback.
                guard !pendingOutput.isEmpty else { return }
                let stillCurrent = generation == flushGeneration
                budget -= delivered
                if delivered == frames || (stillCurrent && (delivered < wanted || dropsSilenceOverBudget)) {
                    // Done; or silence could not be allocated; or finishing.
                    pendingOutput.removeFirst()
                } else {
                    // Out of budget (or the owner switched devices from a
                    // callback): the rest goes out on a later tick.
                    pendingOutput[0] = .silence(frames: frames - delivered)
                    return
                }
            }
            guard generation == flushGeneration else { return }
        }
    }

    /// Returns the frames handed to the owner (fewer than asked only when a
    /// buffer cannot be allocated or the owner stopped the capture).
    private func deliverSilence(frames: Int) -> Int {
        guard let format, format.sampleRate > 0 else { return 0 }
        let silenceGeneration = generation
        var delivered = 0
        while delivered < frames {
            let chunk = min(frames - delivered, Int(Self.silenceChunkFrames))
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { break }
            silence.frameLength = AVAudioFrameCount(chunk)
            for item in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let data = item.mData { memset(data, 0, Int(item.mDataByteSize)) }
            }
            callback?(silence)
            delivered += chunk
            paddedSecondsTotal += Double(chunk) / format.sampleRate
            guard generation == silenceGeneration else { break }
        }
        return delivered
    }

    /// Frames of padding one delivery may carry: `seconds` of the recording
    /// format (no time cap when nil) and never more than `bytes`.
    static func padFrameBudget(format: AVAudioFormat, seconds: TimeInterval?, bytes: Int) -> Int {
        let frameBytes = max(1, Int(format.channelCount)) * MemoryLayout<Float>.size
        var frames = max(1, bytes / frameBytes)
        if let seconds, seconds.isFinite, format.sampleRate > 0 {
            let bySeconds = seconds * format.sampleRate
            if bySeconds < Double(frames) { frames = max(1, Int(bySeconds.rounded(.down))) }
        }
        return frames
    }

    // MARK: - Silent input

    /// Runs on the serial queue on each real buffer, in the device format,
    /// before conversion. Padding never counts. Stops looking once reported.
    private func trackSilentInput(_ buffer: AVAudioPCMBuffer) {
        guard !silentInputReported, !tearingDown, buffer.frameLength > 0 else { return }
        let rate = buffer.format.sampleRate
        guard rate > 0 else { return }
        guard Self.isDigitalSilence(buffer) else {
            silentInputRunSeconds = 0
            return
        }
        silentInputRunSeconds += Double(buffer.frameLength) / rate
        // A hair of tolerance so 1.5 s summed from buffer lengths counts.
        guard silentInputRunSeconds + 1e-9 >= Self.silentInputDetectionSeconds else { return }
        silentInputReported = true
        deliverInOrder(.event(.silentInput))
    }

    func resetSilentInputDetection() {
        silentInputRunSeconds = 0
        silentInputReported = false
    }

    /// Every sample is exactly 0.0 (negative zero included). Exits at the
    /// first non-zero sample, which for a live mic is almost always the first.
    static func isDigitalSilence(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else { return false }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return false }
        let channelCount = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let pointerCount = interleaved ? 1 : channelCount
        let samplesPerPointer = interleaved ? frames * channelCount : frames
        for index in 0..<pointerCount {
            let data = channels[index]
            for sample in 0..<samplesPerPointer where data[sample] != 0 {
                return false
            }
        }
        return true
    }

    // MARK: - Format

    /// A later device format (another app changed the mic's rate, or a
    /// replacement device) keeps the recording's format and is resampled.
    func acceptFormat(_ current: AVAudioFormat) throws {
        guard let format, !format.isEqual(current) else {
            if format == nil { format = current }
            deviceFormat = current
            converter = nil
            return
        }
        guard let converter = AVAudioConverter(from: current, to: format) else {
            throw Self.error(-3, "Microphone format changed and could not be converted.")
        }
        converter.downmix = current.channelCount > format.channelCount
        deviceFormat = current
        self.converter = converter
    }

    /// Runs on the capture queue, never the IOProc thread.
    private func convertToRecordingFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let format else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }

    func currentFormat(of deviceID: AudioDeviceID) throws -> AVAudioFormat {
        if let hardwareHooks { return try hardwareHooks.currentFormat(deviceID) }
        return try Self.inputFormat(of: deviceID)
    }

    func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        if let hardwareHooks { return hardwareHooks.isAlive(deviceID) }
        return Self.deviceIsAlive(deviceID)
    }
}

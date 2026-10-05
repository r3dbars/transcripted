import Foundation
@preconcurrency import AVFoundation
import FluidAudio
import TranscriptedCore

extension LiveMeetingCaptionTrack {
    init() {
        self.init(recognizer: FluidLiveMeetingCaptionRecognizer(),
                  feedSamples: StreamingChunkSize.ms320.shiftSamples,
                  flushSamples: StreamingChunkSize.ms320.chunkSamples) { message, errorType in
            TranscriptedCore.AppLogger.pipeline.warning(message, ["error_type": errorType])
        }
    }
}

actor FluidLiveMeetingCaptionRecognizer: LiveMeetingCaptionRecognizing {
    // Close at the EOU token itself; the default debounce skips resumed speech.
    private let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 0)
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                      channels: 1, interleaved: false)

    func loadModels() async throws { try await manager.loadModels() }

    func process(_ samples: [Float]) async throws {
        guard let format, !samples.isEmpty,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = pcm.floatChannelData?[0] else { return }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        try await manager.appendAudio(pcm)
        try await manager.processBufferedAudio()
    }

    func partialTranscript() async -> String { await manager.getPartialTranscript() }
    func endOfUtteranceDetected() async -> Bool { await manager.eouDetected }
    func reset() async { await manager.reset() }
    func cleanup() async { await manager.cleanup() }
}

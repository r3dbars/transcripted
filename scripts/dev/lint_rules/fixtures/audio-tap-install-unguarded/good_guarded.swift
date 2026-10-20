// lint-fixture-path: Sources/TranscriptedCore/Audio/AudioFileManager.swift
import AVFoundation

/// Mentions of `node.installTap(onBus: 0, ..., format: nil)` in comments and
/// "installTap(onBus:" in strings are ignored.
extension Audio {
    func startMic(settledGraph: MicGraph, micWriteContext: MicWriteContext, oneLiner: Bool) throws {
        let label = "installTap(onBus: 0, format: nil)"
        _ = label
        if oneLiner {
            try AudioTapInstallGuard.run(operation: "dictation_start") { settledGraph.inputNode.installTap(onBus: 0, bufferSize: 4096, format: settledGraph.recordingFormat) { buffer, _ in
                _ = buffer
            } }
            return
        }
        // Install tap on microphone. The route can still move after the
        // check; the guard makes that a failed start, not a crash.
        try AudioTapInstallGuard.run(operation: "start_recording") {
            if settledGraph.voiceProcessingEnabled {
                settledGraph.inputNode.installTap(onBus: 0, bufferSize: 4096, format: settledGraph.recordingFormat) { [weak self] buffer, _ in
                    self?.handleMicBuffer(buffer, writeContext: micWriteContext)
                }
            } else {
                settledGraph.inputNode.installTap(
                    onBus: 0,
                    bufferSize: 4096,
                    format: settledGraph.recordingFormat
                ) { [weak self] buffer, _ in
                    self?.handleMicBuffer(buffer, writeContext: micWriteContext)
                }
            }
        }
    }
}

// The driver seam's own method declaration and its callers don't match.
protocol TapDriverFixture {
    func installTap(on engine: AVAudioEngine, format: AVAudioFormat, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
}

func useDriver(_ driver: TapDriverFixture, engine: AVAudioEngine, format: AVAudioFormat) throws {
    try driver.installTap(on: engine, format: format) { _ in }
    // Unrelated `format: nil` calls are fine.
    _ = try? PropertyListSerialization.propertyList(from: Data(), options: [], format: nil)
}

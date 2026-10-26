// lint-fixture-path: Sources/Speech/ParakeetEngine.swift
import AVFoundation

// Shape before 1e2b1352e: format: nil took the bus's stale 48 kHz format on
// AirPods. Even inside the guard, nil is wrong.
final class DictationTapFixture {
    func start(engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        try AudioTapInstallGuard.run(operation: "dictation_start") {
            inputNode.installTap(
                onBus: 0,
                bufferSize: TranscriptedConstants.audioTapBufferSize,
                format: nil
            ) { buffer, _ in
                self.consume(buffer)
            }
        }
    }

    func consume(_ buffer: AVAudioPCMBuffer) {}
}

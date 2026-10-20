// lint-fixture-path: Sources/TranscriptedCore/Audio/AudioDeviceRecovery.swift
import AVFoundation

// Shape of AudioDeviceRecovery before e25b7ee5f: the format check passed, then
// AirPods flipped to 24 kHz and installTap raised an uncatchable exception.
extension Audio {
    func rebuildMicGraph(engine: AVAudioEngine, recordingFormat: AVAudioFormat, micWriteContext: MicWriteContext) throws {
        let newInputNode = engine.inputNode
        try ensureMicTapFormatStillMatches(
            inputNode: newInputNode,
            expected: recordingFormat,
            operation: "device_recovery"
        )
        newInputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer, writeContext: micWriteContext)
        }
        engine.prepare()
        try engine.start()
    }
}

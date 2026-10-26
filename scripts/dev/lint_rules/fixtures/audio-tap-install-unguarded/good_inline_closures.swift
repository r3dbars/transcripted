// lint-fixture-path: Sources/Speech/FixtureInlineClosures.swift
// autoreleasepool and withExtendedLifetime run inline, so the install is
// still inside the guard.
import AVFoundation
func start(engine: AVAudioEngine, format: AVAudioFormat) throws {
    try AudioTapInstallGuard.run(operation: "mic") {
        autoreleasepool {
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
        }
    }
    try AudioTapInstallGuard.run(operation: "system") {
        withExtendedLifetime(engine) {
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
        }
    }
}

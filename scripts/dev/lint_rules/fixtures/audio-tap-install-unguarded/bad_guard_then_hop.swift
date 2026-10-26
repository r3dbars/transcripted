// lint-fixture-path: Sources/Speech/ParakeetAudioTap.swift
import AVFoundation

// The guard closure returns before the queue runs the install, so the raise
// happens outside it.
final class HoppingTapFixture {
    let queue = DispatchQueue(label: "fixture.audio")

    func start(node: AVAudioInputNode, format: AVAudioFormat) throws {
        try AudioTapInstallGuard.run(operation: "dictation_start") {
            self.queue.async {
                node.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
            }
        }
    }
}

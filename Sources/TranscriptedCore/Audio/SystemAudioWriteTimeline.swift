import Foundation
@preconcurrency import AVFoundation

/// One exact writer's provenance. All journal and AVAudioFile access is on
/// Audio's existing serial system-file queue, never the HAL callback or main.
final class SystemAudioWriteTimeline: @unchecked Sendable {
    private weak var writer: AVAudioFile?
    private var identity: RecordedSystemAudioTimeline.Identity?
    private var journal: RecordedSystemAudioTimeline.Journal?
    private let completionLock = NSLock()
    private var completed: RecordedSystemAudioTimeline?

    func install(writer: AVAudioFile, generation: UInt64) {
        guard identity == nil else { return }
        let identity = RecordedSystemAudioTimeline.Identity(
            generation: generation, captureAttempt: UUID(), writer: UUID()
        )
        self.writer = writer
        self.identity = identity
        // Worst case ~40 MiB, released after transcription handoff. Exact
        // slopes may not coalesce on real hardware. Saturation withholds the
        // suffix; long-call capacity qualification remains necessary.
        journal = RecordedSystemAudioTimeline.Journal(
            identity: identity, sampleRate: writer.processingFormat.sampleRate,
            maximumSegments: 1_048_576
        )
    }

    func write(_ buffer: AVAudioPCMBuffer, to writer: AVAudioFile,
               timing: SystemAudioBufferTiming = .unavailable) throws {
        let start = writer.framePosition
        var succeeded = false
        defer {
            if self.writer === writer, let identity {
                journal?.recordWrite(
                    identity: identity, startFrame: start, endFrame: writer.framePosition,
                    frameCount: Int64(buffer.frameLength), succeeded: succeeded, timing: timing
                )
            }
        }
        try writer.write(from: buffer)
        succeeded = true
    }

    /// Called only after capture's admitted tail and all file writes drain.
    func finish(writer: AVAudioFile) {
        guard self.writer === writer, var journal else { return }
        let snapshot = journal.finish()
        self.journal = nil
        completionLock.lock()
        completed = snapshot
        completionLock.unlock()
    }

    /// Lock publishes immutable metadata only; no file access or queue wait.
    func takeFinished() -> RecordedSystemAudioTimeline? {
        completionLock.lock(); defer { completionLock.unlock() }
        defer { completed = nil }
        return completed
    }
}

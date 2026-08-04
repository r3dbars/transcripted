import XCTest
@testable import TranscriptedCore

/// Coordinates a Task-cancellation test so the cancellation is guaranteed to be visible
/// *before* the task under test ever calls `Task.checkCancellation()`. `Task.cancel()` is
/// synchronous, but a bare `Task { ... }` may start running on another thread before the
/// caller gets around to cancelling it — gating the task body behind this continuation
/// removes that race instead of relying on a sleep-then-cancel timing guess.
private actor CancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func waitUntilOpened() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CallRecorder {
    private(set) var order: [String] = []

    func record(_ label: String) {
        order.append(label)
    }
}

/// Covers `PipelineRollbackRegistry`, the accumulator `transcribeMultichannelPipeline` /
/// `transcribeMicrophoneOnlyPipeline` use so a late cancellation rolls back exactly the side
/// effects that happened by that point, without every checkpoint re-stating a growing
/// "what to clean up" parameter list (see `Sources/TranscriptedCore/Pipeline/TranscriptionPipelineRunner.swift`).
///
/// Two layers:
///  - Generic registry mechanics (order, idempotency, non-cancelled no-op).
///  - The three real `TranscriptionTaskManager.register*Rollback` helpers the pipeline calls at
///    each checkpoint, driven directly against real temp-file artifacts standing in for a saved
///    transcript, retained audio, and extracted speaker clips — so "cancelled at checkpoint N"
///    is simulated by registering exactly the helpers a real run would have called by stage N
///    and nothing more, then asserting only those artifacts get cleaned.
@available(macOS 14.0, *)
final class PipelineRollbackRegistryTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineRollbackRegistryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        super.tearDown()
    }

    // MARK: - Generic registry mechanics

    func testCheckCancellationDoesNothingWhenNotCancelled() async throws {
        let rollback = PipelineRollbackRegistry()
        let recorder = CallRecorder()
        rollback.register { await recorder.record("undo") }

        try await rollback.checkCancellation()

        let order = await recorder.order
        XCTAssertTrue(order.isEmpty, "a non-cancelled checkpoint must not run any registered undo")
    }

    func testCheckCancellationRunsRegisteredUndosMostRecentlyRegisteredFirstThenRethrows() async throws {
        let rollback = PipelineRollbackRegistry()
        let recorder = CallRecorder()
        rollback.register { await recorder.record("first") }
        rollback.register { await recorder.record("second") }
        rollback.register { await recorder.record("third") }

        let gate = CancellationGate()
        let task = Task {
            await gate.waitUntilOpened()
            try await rollback.checkCancellation()
        }
        task.cancel()
        await gate.open()

        do {
            try await task.value
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        }

        let order = await recorder.order
        XCTAssertEqual(order, ["third", "second", "first"], "undos run LIFO: most-recently-registered first")
    }

    func testRollbackAllIsIdempotent() async {
        let rollback = PipelineRollbackRegistry()
        let recorder = CallRecorder()
        rollback.register { await recorder.record("undo") }

        await rollback.rollbackAll()
        await rollback.rollbackAll()

        let order = await recorder.order
        XCTAssertEqual(order, ["undo"], "a second rollbackAll() must be a no-op — undos are consumed as they run")
    }

    /// `rollbackAll()`'s undo loop never calls `Task.checkCancellation()` itself — it must not,
    /// or a cleanup started because the task was cancelled would abort partway through and leak
    /// whatever hadn't run yet. Prove every registered undo still executes even while the ambient
    /// task is (already, genuinely) cancelled throughout the entire call.
    func testRollbackAllRunsEveryUndoEvenWhileTheAmbientTaskIsAlreadyCancelled() async throws {
        let rollback = PipelineRollbackRegistry()
        let recorder = CallRecorder()
        rollback.register { await recorder.record("first") }
        rollback.register { await recorder.record("second") }
        rollback.register { await recorder.record("third") }

        let gate = CancellationGate()
        let task = Task {
            await gate.waitUntilOpened()
            XCTAssertTrue(Task.isCancelled, "the task must genuinely be cancelled going into rollbackAll()")
            await rollback.rollbackAll()
        }
        task.cancel()
        await gate.open()
        await task.value

        let order = await recorder.order
        XCTAssertEqual(order, ["third", "second", "first"], "cleanup mid-cancellation must still run to completion, LIFO")
    }

    // MARK: - registerSavedTranscriptRollback

    func testRegisterSavedTranscriptRollbackDeletesSavedFileWhenNoReplacement() async throws {
        let savedURL = tempRoot.appendingPathComponent("Call_2026-08-03.md")
        try Data("saved transcript".utf8).write(to: savedURL)
        let rollback = PipelineRollbackRegistry()

        TranscriptionTaskManager.registerSavedTranscriptRollback(
            savedURL: savedURL,
            replacementTranscriptRollback: nil,
            into: rollback
        )
        await rollback.rollbackAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path), "a fresh save with no replacement target should be deleted on rollback")
    }

    func testRegisterSavedTranscriptRollbackRestoresOriginalFileWhenReplacing() async throws {
        let targetURL = tempRoot.appendingPathComponent("Reviewed_Call.md")
        let originalContents = "original reviewed transcript"
        try Data(originalContents.utf8).write(to: targetURL)
        let replacementRollback = try XCTUnwrap(
            try TranscriptionTaskManager.ReplacementTranscriptRollback.capture(for: targetURL),
            "capture() should snapshot an existing target file"
        )

        // Simulate the pipeline overwriting the file in place with new content.
        try Data("replacement transcript".utf8).write(to: targetURL)

        let rollback = PipelineRollbackRegistry()
        TranscriptionTaskManager.registerSavedTranscriptRollback(
            savedURL: targetURL,
            replacementTranscriptRollback: replacementRollback,
            into: rollback
        )
        await rollback.rollbackAll()

        XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path), "a replacement rollback restores, never deletes, the target file")
        let restored = try String(contentsOf: targetURL, encoding: .utf8)
        XCTAssertEqual(restored, originalContents)
    }

    // MARK: - registerRetainedAudioRollback

    func testRegisterRetainedAudioRollbackRemovesFilesAndEmptyDirectory() async throws {
        let audioDirectory = tempRoot.appendingPathComponent("Call_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let micURL = audioDirectory.appendingPathComponent("microphone.wav")
        let systemURL = audioDirectory.appendingPathComponent("system_audio.wav")
        try Data("mic".utf8).write(to: micURL)
        try Data("system".utf8).write(to: systemURL)

        let rollback = PipelineRollbackRegistry()
        TranscriptionTaskManager.registerRetainedAudioRollback(
            directory: audioDirectory,
            urls: [micURL, systemURL],
            into: rollback
        )
        await rollback.rollbackAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioDirectory.path), "an emptied archive directory should be removed too")
    }

    func testRegisterRetainedAudioRollbackKeepsDirectoryWhenNotEmpty() async throws {
        let audioDirectory = tempRoot.appendingPathComponent("Call_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let micURL = audioDirectory.appendingPathComponent("microphone.wav")
        let unrelatedURL = audioDirectory.appendingPathComponent("unrelated.txt")
        try Data("mic".utf8).write(to: micURL)
        try Data("leave me".utf8).write(to: unrelatedURL)

        let rollback = PipelineRollbackRegistry()
        // Only the mic URL was ever archived by this run — mirrors a run that only ever got as
        // far as retaining one file before something else (out of scope here) wrote a neighbor.
        TranscriptionTaskManager.registerRetainedAudioRollback(
            directory: audioDirectory,
            urls: [micURL],
            into: rollback
        )
        await rollback.rollbackAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioDirectory.path), "a non-empty directory must survive rollback")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    func testRegisterRetainedAudioRollbackNoOpWhenNothingArchived() async {
        let rollback = PipelineRollbackRegistry()
        TranscriptionTaskManager.registerRetainedAudioRollback(directory: nil, urls: [], into: rollback)

        let recorder = CallRecorder()
        // No undo should have been registered at all — prove it by registering a sentinel
        // afterwards and checking rollbackAll() only ever ran the sentinel.
        rollback.register { await recorder.record("sentinel") }
        await rollback.rollbackAll()

        let order = await recorder.order
        XCTAssertEqual(order, ["sentinel"], "an archive outcome with nothing retained should register no undo")
    }

    // MARK: - registerSpeakerClipsRollback

    func testRegisterSpeakerClipsRollbackOnlyRemovesRegisteredChannelClips() async throws {
        let clipsDirectory = tempRoot.appendingPathComponent("clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        let systemClipURL = clipsDirectory.appendingPathComponent("system_speaker_0.caf")
        let micClipURL = clipsDirectory.appendingPathComponent("mic_speaker_0.caf")
        try Data("system clip".utf8).write(to: systemClipURL)
        try Data("mic clip".utf8).write(to: micClipURL)

        // Cancellation at the "system clips extracted, mic clips not reached yet" checkpoint:
        // only the system-channel helper has been called so far.
        let rollback = PipelineRollbackRegistry()
        TranscriptionTaskManager.registerSpeakerClipsRollback([systemClipURL], channel: "system", into: rollback)
        await rollback.rollbackAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: systemClipURL.path), "the registered channel's clip should be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: micClipURL.path), "a clip from a channel not yet registered must survive")
    }

    func testRegisterSpeakerClipsRollbackNoOpWhenNoClipsExtracted() async {
        let rollback = PipelineRollbackRegistry()
        TranscriptionTaskManager.registerSpeakerClipsRollback([], channel: "system", into: rollback)

        let recorder = CallRecorder()
        rollback.register { await recorder.record("sentinel") }
        await rollback.rollbackAll()

        let order = await recorder.order
        XCTAssertEqual(order, ["sentinel"], "extraction that produced zero clips should register no undo")
    }

    // MARK: - Mic-only pipeline shape

    /// `transcribeMicrophoneOnlyPipeline` only ever has two cancellation checkpoints — save,
    /// then archive — with no speaker clips and no naming request, unlike the six-checkpoint
    /// multichannel shape covered below. Drives the same two production helpers in the same
    /// order that function uses, so a regression that (for example) started registering a third
    /// category for the mic-only path would show up here.
    func testMicOnlyPipelineShapeOnlyEverRegistersTranscriptAndRetainedAudio() async throws {
        let root = tempRoot.appendingPathComponent("mic-only", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let savedURL = root.appendingPathComponent("Call.md")
        try Data("mic-only transcript".utf8).write(to: savedURL)
        let audioDirectory = root.appendingPathComponent("Call_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let micAudioURL = audioDirectory.appendingPathComponent("microphone.wav")
        try Data("mic".utf8).write(to: micAudioURL)

        let rollback = PipelineRollbackRegistry()
        TranscriptionTaskManager.registerSavedTranscriptRollback(savedURL: savedURL, replacementTranscriptRollback: nil, into: rollback)
        TranscriptionTaskManager.registerRetainedAudioRollback(directory: audioDirectory, urls: [micAudioURL], into: rollback)

        await rollback.rollbackAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioDirectory.path))
    }

    // MARK: - Full checkpoint sequence (multichannel pipeline, checkpoints 1-4)

    /// Builds the artifacts a real `transcribeMultichannelPipeline` run would have produced by
    /// cancellation checkpoints 1-4, registering rollback with the exact production helpers at
    /// each stage reached, then simulates cancellation landing at `stage`. Artifact creation
    /// itself is gated by `stage`, not just registration — a "cancelled at checkpoint N" case
    /// must not have later-stage files on disk at all, matching a real run that never got that
    /// far, so a truncated run genuinely proves its stated boundary instead of merely leaving an
    /// unregistered-but-present file untouched.
    ///
    /// Checkpoints 5 and 6 (the bare recheck before enqueuing, and dequeuing the just-queued
    /// speaker naming request) need a real `TranscriptionTaskManager` to exercise for real —
    /// `cancelSpeakerNamingRequest` mutates manager-owned queue state and its own clip cleanup —
    /// so those are covered separately in `PipelineRollbackRegistryManagerTests.swift` against
    /// production `enqueueSpeakerNamingRequest`/`cancelSpeakerNamingRequest`, not a stand-in here.
    private struct StageArtifacts {
        var savedURL: URL
        var retainedAudioDirectory: URL?
        var retainedAudioURLs: [URL] = []
        var systemClipURLs: [URL] = []
        var micClipURLs: [URL] = []
    }

    private func runCheckpointSequence(upTo stage: Int, in root: URL) throws -> (rollback: PipelineRollbackRegistry, artifacts: StageArtifacts) {
        precondition((1...4).contains(stage), "this harness only models checkpoints 1-4; see the doc comment above")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rollback = PipelineRollbackRegistry()

        // Checkpoint 1: transcript saved.
        let savedURL = root.appendingPathComponent("Call.md")
        try Data("transcript".utf8).write(to: savedURL)
        TranscriptionTaskManager.registerSavedTranscriptRollback(savedURL: savedURL, replacementTranscriptRollback: nil, into: rollback)
        var artifacts = StageArtifacts(savedURL: savedURL)
        guard stage >= 2 else { return (rollback, artifacts) }

        // Checkpoint 2: recording audio archived.
        let audioDirectory = root.appendingPathComponent("Call_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let micAudioURL = audioDirectory.appendingPathComponent("microphone.wav")
        let systemAudioURL = audioDirectory.appendingPathComponent("system_audio.wav")
        try Data("mic".utf8).write(to: micAudioURL)
        try Data("system".utf8).write(to: systemAudioURL)
        TranscriptionTaskManager.registerRetainedAudioRollback(directory: audioDirectory, urls: [micAudioURL, systemAudioURL], into: rollback)
        artifacts.retainedAudioDirectory = audioDirectory
        artifacts.retainedAudioURLs = [micAudioURL, systemAudioURL]
        guard stage >= 3 else { return (rollback, artifacts) }

        // Checkpoint 3: system speaker clips extracted.
        let clipsDirectory = root.appendingPathComponent("clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        let systemClipURL = clipsDirectory.appendingPathComponent("system_speaker_0.caf")
        try Data("system clip".utf8).write(to: systemClipURL)
        TranscriptionTaskManager.registerSpeakerClipsRollback([systemClipURL], channel: "system", into: rollback)
        artifacts.systemClipURLs = [systemClipURL]
        guard stage >= 4 else { return (rollback, artifacts) }

        // Checkpoint 4: mic speaker clips extracted.
        let micClipURL = clipsDirectory.appendingPathComponent("mic_speaker_0.caf")
        try Data("mic clip".utf8).write(to: micClipURL)
        TranscriptionTaskManager.registerSpeakerClipsRollback([micClipURL], channel: "mic", into: rollback)
        artifacts.micClipURLs = [micClipURL]

        return (rollback, artifacts)
    }

    func testCancellationAtSaveCheckpointOnlyEverCreatesAndRemovesTranscript() async throws {
        let root = tempRoot.appendingPathComponent("stage1", isDirectory: true)
        let (rollback, artifacts) = try runCheckpointSequence(upTo: 1, in: root)

        // Prove the boundary, not just the cleanup: a run cancelled this early never even
        // creates the later-stage directories, exactly like a real pipeline that never reached
        // archiving or clip extraction.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Call_audio").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("clips").path))

        await rollback.rollbackAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.savedURL.path))
    }

    func testCancellationAfterArchiveCheckpointRemovesTranscriptAndRetainedAudioButNeverCreatedClips() async throws {
        let root = tempRoot.appendingPathComponent("stage2", isDirectory: true)
        let (rollback, artifacts) = try runCheckpointSequence(upTo: 2, in: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("clips").path), "a run cancelled before clip extraction never creates the clips directory")

        await rollback.rollbackAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.savedURL.path))
        for url in artifacts.retainedAudioURLs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        if let directory = artifacts.retainedAudioDirectory {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testCancellationAfterSystemClipsCheckpointAlsoRemovesSystemClipsButNeverCreatedMicClip() async throws {
        let root = tempRoot.appendingPathComponent("stage3", isDirectory: true)
        let (rollback, artifacts) = try runCheckpointSequence(upTo: 3, in: root)
        // The mic clip's checkpoint (4) was never reached, so — unlike the isolated
        // registerSpeakerClipsRollback unit test above, which deliberately creates both clips to
        // prove channel scoping — this file genuinely does not exist yet.
        let micClipURL = root.appendingPathComponent("clips", isDirectory: true).appendingPathComponent("mic_speaker_0.caf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: micClipURL.path), "a run cancelled before mic extraction never creates the mic clip")

        await rollback.rollbackAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.savedURL.path))
        for url in artifacts.systemClipURLs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testCancellationAfterMicClipsCheckpointRemovesBothChannelsClips() async throws {
        let root = tempRoot.appendingPathComponent("stage4", isDirectory: true)
        let (rollback, artifacts) = try runCheckpointSequence(upTo: 4, in: root)

        await rollback.rollbackAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.savedURL.path))
        for url in artifacts.retainedAudioURLs + artifacts.systemClipURLs + artifacts.micClipURLs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
}

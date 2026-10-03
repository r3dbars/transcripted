import Combine
import Foundation
import TranscriptedCore

/// Streams each dictation through the same Parakeet EOU recognizer the
/// meeting live transcript uses (`LiveMeetingCaptionTrack`), so the island
/// can show the words as they're spoken.
///
/// It never sits on the dictation's own path:
/// - The model load starts once the dictation model is ready and nothing is
///   being dictated (a dictation begun mid-load can overlap it), the warmup
///   inference re-checks, and then it stays loaded. Until it's ready the hover has no words.
/// - Audio is a copy the capture queue already makes (`STTRouter
///   .setDictationPreviewSink`); nothing new runs on the mic's thread and no
///   audio engine is built or touched, so a Bluetooth headset sees nothing
///   new.
/// - Feeding stops at key-up (`releaseRequested`), before the mic even
///   stops, and the track feeds one 320 ms chunk at a time, so the final
///   transcription waits behind at most one chunk already on the Neural
///   Engine. The next take's feeding waits until that final pass is done,
///   and so does resetting the recognizer.
/// - Start and stop bookkeeping runs on the next main-loop turn, never
///   inside the recording state change.
/// - Not during a meeting: there the hover shows the meeting's transcript.
///
/// `TRANSCRIPTED_DICTATION_PREVIEW=off` turns it off (no model load);
/// `alternate` streams every other take, for an A/B of dictation latency.
/// Each take logs `Dictation live preview` with `state` on/off/not_ready.
///
/// Measured on an M5 Max (FluidAudio 0.17): about 10 ms of Neural Engine
/// time per 320 ms of speech, and no measurable change to the final pass.
/// The text never reaches disk, logs or telemetry.
@MainActor
final class LiveDictationCaptions: ObservableObject {
    enum Status: Equatable, Sendable {
        case off
        case preparing
        case ready
        case unavailable
    }

    enum Mode: String {
        case on
        case off
        case alternate

        static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Mode {
            environment["TRANSCRIPTED_DICTATION_PREVIEW"].flatMap { Mode(rawValue: $0.lowercased()) } ?? .on
        }
    }

    static let shared = LiveDictationCaptions()

    @Published private(set) var preview = LiveDictationPreview()
    @Published private(set) var status: Status = .off
    /// True from the start of a take until it stops: the hover has words to
    /// show for this dictation.
    @Published private(set) var isStreaming = false

    /// The earliest the model loads after launch, so it never competes with
    /// app startup.
    static let loadDelay: Duration = .seconds(8)
    private static let pumpInterval: Duration = .milliseconds(100)

    private let track = LiveMeetingCaptionTrack()
    private let mode = Mode.fromEnvironment()
    private weak var router: STTRouter?
    private var recordingWatch: AnyCancellable?
    private var transcribingWatch: AnyCancellable?
    private var pump: Task<Void, Never>?
    private var events: Task<Void, Never>?
    /// Start and pause run in order, so a quick release-and-press can't
    /// pause the take that just began.
    private var lifecycle: Task<Void, Never>?
    private var generation = 0
    private var takeCount = 0
    /// The take the words belong to. A device recovery restarts recording
    /// inside one take; its words stay.
    private var previewTake: UUID?
    /// `alternate` skipped this take; a recovery restart inside it stays off.
    private var previewTakeSkipped = false
    /// This take's "don't feed" switch, read by the track's drain and the
    /// pump on their own tasks. One per take, so a take that ended can never
    /// feed again.
    private var takeStopped: Flag?
    /// A take that was just released is still being transcribed. Feeding and
    /// resets wait, so the preview never shares the Neural Engine with that
    /// final pass.
    nonisolated private let finalPassRunning = Flag(false)

    /// Called once with the app's router: loads the model when idle and
    /// follows the router's recording state from then on.
    func attach(router: STTRouter) {
        // Harness launches don't download or load another model.
        guard self.router == nil, mode != .off, !AutomatedLaunchEnvironment.isActive() else { return }
        self.router = router
        recordingWatch = router.$isRecording
            .removeDuplicates()
            .sink { [weak self] recording in
                // Next turn: nothing here runs inside the recording change.
                DispatchQueue.main.async { self?.recordingChanged(recording) }
            }
        transcribingWatch = router.$isTranscribing
            .removeDuplicates()
            .sink { [finalPassRunning] transcribing in finalPassRunning.set(transcribing) }
        lifecycle = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: Self.loadDelay)
            await self?.load()
        }
    }

    /// The key went up: stop feeding now, a beat before recording stops.
    func releaseRequested() {
        takeStopped?.set(true)
    }

    private var isIdle: Bool {
        guard let router else { return false }
        return router.isRecordingModelLoaded && !router.isRecording && !router.isTranscribing
    }

    /// Waits for `isIdle` by waking on the router's state changes instead of
    /// polling. `@Published` emits before the value lands, so each wake
    /// re-checks on a later main-actor turn. A slow backstop re-check covers
    /// the parts of `isRecordingModelLoaded` that aren't published (the
    /// recording lease and foreground warmup) and a router that went away.
    private func waitUntilIdle() async {
        guard !isIdle, !Task.isCancelled else { return }
        let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var watch: AnyCancellable?
        if let router {
            watch = Publishers.MergeMany([
                router.$isRecording.map { _ in () }.eraseToAnyPublisher(),
                router.$isTranscribing.map { _ in () }.eraseToAnyPublisher(),
                router.$modelDownloadState.map { _ in () }.eraseToAnyPublisher(),
                router.$selectedModel.map { _ in () }.eraseToAnyPublisher(),
                router.parakeetEngine.$modelDownloadState.map { _ in () }.eraseToAnyPublisher(),
            ])
            .sink { wake.yield() }
        }
        let backstop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                wake.yield()
            }
        }
        defer {
            watch?.cancel()
            backstop.cancel()
            wake.finish()
        }
        // Ends on cancellation too: an `AsyncStream` iterator returns nil then.
        for await _ in wakes where isIdle || Task.isCancelled {
            return
        }
    }

    private func load() async {
        // The dictation model loads first, and never alongside a dictation.
        await waitUntilIdle()
        guard status == .off else { return }
        status = .preparing
        let result = await track.load(beforeWarmup: { [weak self] in
            await self?.waitUntilIdle()
        })
        status = result == .ready ? .ready : .unavailable
    }

    private func recordingChanged(_ recording: Bool) {
        // A change that was already undone by the time this turn ran.
        guard recording == router?.isRecording else { return }
        guard recording else { return end() }
        // Every take starts clean, streamed or not, so the hover can never
        // show the last take's words.
        let take = router?.dictationRecordingIdentity
        let isNewTake = take != previewTake
        if isNewTake {
            previewTake = take
            preview = LiveDictationPreview()
            takeCount += 1
            previewTakeSkipped = mode == .alternate && takeCount.isMultiple(of: 2)
        }
        let state = begin(skipping: previewTakeSkipped)
        if isNewTake {
            AppLogger.pipeline.info("Dictation live preview", ["state": state])
        }
    }

    /// Starts streaming this take. Returns its state for the log.
    private func begin(skipping: Bool) -> String {
        guard !isStreaming else { return "on" }
        guard status == .ready, let router else { return "not_ready" }
        guard !skipping,
              !router.isRecordingFromSharedMeetingMic,
              !LiveMeetingTranscriptService.shared.isRecording else { return "off" }
        generation += 1
        let generation = generation
        isStreaming = true
        let stopped = Flag(false)
        takeStopped = stopped

        let sink = DictationPreviewSampleSink()
        router.setDictationPreviewSink(sink)
        let queue = track.queue
        let finalPassRunning = finalPassRunning
        // Off the main thread: resampling is the only real work here.
        pump = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let samples = sink.take()
                // A take that ended mustn't leak its tail into the next one:
                // the append happens under the flag's lock, and `end()` sets
                // the flag before it clears the queue.
                if !samples.isEmpty { stopped.unlessSet { queue.append(samples) } }
                try? await Task.sleep(for: Self.pumpInterval)
            }
        }
        // One consumer, in order: a commit can never be dropped behind a
        // partial that overtook it.
        let (stream, continuation) = AsyncStream<LiveMeetingCaptionTrack.Event>.makeStream()
        events = Task { [weak self] in
            for await event in stream {
                guard let self, generation == self.generation else { continue }
                self.apply(event)
            }
        }
        let previous = lifecycle
        lifecycle = Task(priority: .utility) { [track] in
            await previous?.value
            await track.start(shouldYield: { stopped.value || finalPassRunning.value }) { event, _ in
                continuation.yield(event)
            }
        }
        return "on"
    }

    /// Recording stopped (released, cancelled, failed, or a recovery
    /// restart). Feeding stops at once; the words heard so far stay up so the
    /// hover doesn't flicker while the final text is written.
    private func end() {
        guard isStreaming else { return }
        takeStopped?.set(true)
        takeStopped = nil
        // Clear now, not in the queued pause, so the next take's first audio
        // isn't the one dropped.
        track.queue.removeAll()
        isStreaming = false
        generation += 1
        pump?.cancel()
        pump = nil
        events?.cancel()
        events = nil
        router?.setDictationPreviewSink(nil)
        // What was still being heard stays, settled, through the release.
        preview.commit(preview.tentative)
        let previous = lifecycle
        let finalPassRunning = finalPassRunning
        lifecycle = Task(priority: .utility) { [track] in
            await previous?.value
            // Resetting allocates the recognizer's caches again; do it after
            // the final pass, not during it. The pass may not have started
            // yet, so give it a moment to.
            try? await Task.sleep(for: .milliseconds(300))
            var waited = 0
            while finalPassRunning.value, waited < 100 {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 1
            }
            await track.pause()
        }
    }

    private func apply(_ event: LiveMeetingCaptionTrack.Event) {
        switch event {
        case .partial(let text): preview.tentative = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .utterance(let text): preview.commit(text)
        }
    }
}

/// Set on the main actor, read on the track's and the pump's own tasks.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Bool

    init(_ value: Bool) { current = value }

    var value: Bool { lock.withLock { current } }

    func set(_ value: Bool) { lock.withLock { current = value } }

    /// Runs `work` only while unset, holding the lock so `set(true)` can't
    /// land halfway through it.
    func unlessSet(_ work: () -> Void) {
        lock.withLock { if !current { work() } }
    }
}

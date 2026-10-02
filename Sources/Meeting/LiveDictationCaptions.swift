import Combine
import Foundation

/// Streams each dictation through the same Parakeet EOU recognizer the
/// meeting live transcript uses (`LiveMeetingCaptionTrack`), so the island
/// can show the words as they're spoken.
///
/// It never sits on the dictation's own path:
/// - The model loads once, at idle after launch, never during a key press,
///   and stays loaded. Until it's ready the hover just has no words.
/// - Audio is a copy the capture queue already makes (`STTRouter
///   .setDictationPreviewSink`); nothing new runs on the mic's thread and no
///   audio engine is built or touched, so a Bluetooth headset sees nothing
///   new.
/// - The moment recording stops, feeding stops; the final transcription
///   runs exactly as before and never waits for the preview.
/// - Not during a meeting: there the hover shows the meeting's transcript.
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

    static let shared = LiveDictationCaptions()

    @Published private(set) var preview = LiveDictationPreview()
    @Published private(set) var status: Status = .off
    /// True from the start of a take until it stops: the hover has words to
    /// show for this dictation.
    @Published private(set) var isStreaming = false

    /// How long after launch the model loads, so it never competes with
    /// app startup or the dictation model's own warmup.
    static let loadDelay: Duration = .seconds(8)
    private static let pumpInterval: Duration = .milliseconds(100)

    private let track = LiveMeetingCaptionTrack()
    private weak var router: STTRouter?
    private var recordingWatch: AnyCancellable?
    private var pump: Task<Void, Never>?
    /// Start and pause run in order, so a quick release-and-press can't
    /// pause the take that just began.
    private var lifecycle: Task<Void, Never>?
    private var generation = 0
    private var lastSequence = -1
    /// The take the words belong to. A device recovery restarts recording
    /// inside one take; its words stay.
    private var previewTake: UUID?
    /// This take's "don't feed" switch, read by the track's drain on its own
    /// task. One per take, so a take that ended can never feed again.
    private var takeStopped: Flag?
    /// A take that was just released is still being transcribed. The next
    /// take's drain waits, so it never shares the Neural Engine with that
    /// final pass; its audio queues and catches up.
    nonisolated private let finalPassRunning = Flag(false)
    private var transcribingWatch: AnyCancellable?

    /// Called once with the app's router: loads the model at idle and
    /// follows the router's recording state from then on.
    func attach(router: STTRouter) {
        // Harness launches don't download or load another model.
        guard self.router == nil, !AutomatedLaunchEnvironment.isActive() else { return }
        self.router = router
        recordingWatch = router.$isRecording
            .removeDuplicates()
            .sink { [weak self] recording in
                MainActor.assumeIsolated { self?.recordingChanged(recording) }
            }
        transcribingWatch = router.$isTranscribing
            .removeDuplicates()
            .sink { [finalPassRunning] transcribing in finalPassRunning.set(transcribing) }
        lifecycle = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: Self.loadDelay)
            await self?.load()
        }
    }

    private func load() async {
        // Wait out a dictation in progress; the load is the one heavy step.
        while let router, router.isRecording || router.isTranscribing {
            try? await Task.sleep(for: .seconds(2))
        }
        guard status == .off else { return }
        status = .preparing
        status = await track.load() == .ready ? .ready : .unavailable
    }

    private func recordingChanged(_ recording: Bool) {
        guard recording else { return end() }
        // Every take starts clean, streamed or not, so the hover can never
        // show the last take's words.
        let take = router?.dictationRecordingIdentity
        if take != previewTake {
            previewTake = take
            preview = LiveDictationPreview()
        }
        begin()
    }

    private func begin() {
        guard status == .ready, let router, !isStreaming,
              !router.isRecordingFromSharedMeetingMic,
              !LiveMeetingTranscriptService.shared.isRecording else { return }
        generation += 1
        let generation = generation
        lastSequence = -1
        isStreaming = true
        let stopped = Flag(false)
        takeStopped = stopped

        let sink = DictationPreviewSampleSink()
        router.setDictationPreviewSink(sink)
        let queue = track.queue
        // Off the main thread: resampling is the only real work here.
        pump = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let samples = sink.take()
                // A take that ended mustn't leak its tail into the next one.
                if !samples.isEmpty, !stopped.value { queue.append(samples) }
                try? await Task.sleep(for: Self.pumpInterval)
            }
        }
        let previous = lifecycle
        let finalPassRunning = finalPassRunning
        lifecycle = Task(priority: .utility) { [weak self, track] in
            await previous?.value
            await track.start(shouldYield: { stopped.value || finalPassRunning.value }) { event, sequence in
                Task { @MainActor [weak self] in self?.apply(event, sequence: sequence, generation: generation) }
            }
        }
    }

    /// Recording stopped (released, cancelled or failed). Feeding stops at
    /// once; the words heard so far stay up until the next take so the
    /// hover doesn't flicker while the final text is written.
    private func end() {
        guard isStreaming else { return }
        takeStopped?.set(true)
        takeStopped = nil
        // Clear now, not in the queued pause, so the next take's first audio
        // isn't the one dropped.
        track.queue.removeAll()
        // What was still being heard stays, settled, through the release.
        preview.commit(preview.tentative)
        isStreaming = false
        generation += 1
        pump?.cancel()
        pump = nil
        router?.setDictationPreviewSink(nil)
        let previous = lifecycle
        lifecycle = Task(priority: .utility) { [track] in
            await previous?.value
            await track.pause()
        }
    }

    private func apply(_ event: LiveMeetingCaptionTrack.Event, sequence: Int, generation: Int) {
        guard generation == self.generation, sequence > lastSequence else { return }
        lastSequence = sequence
        switch event {
        case .partial(let text): preview.tentative = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .utterance(let text): preview.commit(text)
        }
    }
}

/// Set on the main actor, read by the track's drain on its own task.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Bool

    init(_ value: Bool) { current = value }

    var value: Bool { lock.withLock { current } }

    func set(_ value: Bool) { lock.withLock { current = value } }
}

import Combine
import Foundation
import Synchronization

/// The live transcript the island shows while a meeting records: two
/// streaming recognizers (your mic, the call) fed from the same live-PCM tap
/// the agent preview uses. Runs only when "Live transcript" is on in
/// Settings, only while recording, and never touches the audio engine or the
/// saved meeting, which is transcribed again after Stop. Nothing here leaves
/// the Mac or reaches the logs.
@MainActor
final class LiveMeetingCaptions: ObservableObject {
    enum Status: Equatable, Sendable {
        case off
        /// Downloading (first meeting only) or loading the models.
        case preparing
        case listening
        case unavailable
    }

    static let shared = LiveMeetingCaptions()

    @Published private(set) var log = LiveMeetingCaptionLog()
    @Published private(set) var status: Status = .off

    /// Read on the live-PCM queue: whether offered audio has anywhere to go.
    nonisolated private let accepting = Atomic<Bool>(false)
    nonisolated private let microphone = LiveMeetingCaptionTrack()
    nonisolated private let system = LiveMeetingCaptionTrack()
    private var sessionID: UUID?
    private var generation = 0
    private var startTask: Task<Void, Never>?
    /// The last stop's model cleanup; a new start waits for it so it can't
    /// free the models the new start just loaded.
    private var teardown: Task<Void, Never>?

    var isActive: Bool { status != .off }

    /// Starts transcribing this recording. Clears the last meeting's text.
    func start(sessionID: UUID, shouldYield: @escaping @MainActor () -> Bool) {
        guard self.sessionID != sessionID || status == .off else { return }
        stopTracks()
        self.sessionID = sessionID
        generation += 1
        let generation = generation
        log = LiveMeetingCaptionLog()
        status = .preparing
        // Audio queues while the models load, up to the tracks' bound.
        accepting.store(true, ordering: .releasing)
        let yield: @Sendable () async -> Bool = { await MainActor.run { shouldYield() } }
        startTask = Task { [weak self, microphone = self.microphone, system = self.system, teardown = self.teardown] in
            await teardown?.value
            // One at a time: both tracks share one model download.
            let micLoad = await microphone.load()
            let systemLoad = await system.load()
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            guard micLoad == .ready, systemLoad == .ready else {
                self.status = .unavailable
                self.accepting.store(false, ordering: .releasing)
                return
            }
            await microphone.start(shouldYield: yield) { [weak self] event in
                Task { @MainActor [weak self] in self?.apply(event, track: .microphone, generation: generation) }
            }
            await system.start(shouldYield: yield) { [weak self] event in
                Task { @MainActor [weak self] in self?.apply(event, track: .system, generation: generation) }
            }
            self.status = .listening
        }
    }

    /// The recording ended, or the setting was turned off. The text stays
    /// for the rest of this session so nothing flickers while the island
    /// switches to Transcribing; the next meeting clears it.
    func stop(sessionID: UUID? = nil) {
        if let sessionID, sessionID != self.sessionID { return }
        guard status != .off else { return }
        stopTracks()
        status = .off
    }

    /// Called on Core's live-PCM delivery queue, never a CoreAudio callback.
    /// `samples` are 16 kHz mono.
    nonisolated func offer(_ samples: [Float], track: LiveMeetingTrack) {
        guard accepting.load(ordering: .acquiring), !samples.isEmpty else { return }
        switch track {
        case .microphone: microphone.queue.append(samples)
        case .system: system.queue.append(samples)
        }
    }

    private func stopTracks() {
        accepting.store(false, ordering: .releasing)
        generation += 1
        startTask?.cancel()
        startTask = nil
        teardown = Task { [microphone = self.microphone, system = self.system, teardown = self.teardown] in
            await teardown?.value
            await microphone.stop()
            await system.stop()
        }
    }

    private func apply(_ event: LiveMeetingCaptionTrack.Event, track: LiveMeetingTrack, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .partial(let text): log.setTentative(text, track: track)
        case .utterance(let text): log.commit(text, track: track)
        }
    }
}

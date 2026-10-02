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

    /// This meeting's two recognizers, read on the live-PCM queue. A fresh
    /// pair per meeting, so a stop's cleanup can never reach the next
    /// meeting's models; nil when nothing runs, so an idle app holds no
    /// buffers or models.
    private struct Tracks: Sendable {
        let microphone = LiveMeetingCaptionTrack()
        let system = LiveMeetingCaptionTrack()
    }
    nonisolated private let current = Mutex<Tracks?>(nil)
    private var sessionID: UUID?
    private var lastLogSessionID: UUID?
    /// Per track, the newest event applied, so a partial that lands late
    /// can't bring back words already committed.
    private var lastSequence: [LiveMeetingTrack: Int] = [:]
    private var generation = 0
    private var startTask: Task<Void, Never>?
    /// The last stop's cleanup; a new start waits for it, so two meetings'
    /// models are never loaded at once.
    private var teardown: Task<Void, Never>?

    private var prewarmTask: Task<Void, Never>?
    private var prewarmed = false

    /// Downloads and compiles the model in the background, once per launch,
    /// so a meeting never waits on it. The first Neural Engine compile takes
    /// ~20 s on an M5 and can take a minute on an M1, longer than the 30 s
    /// the tracks can queue. Loads one copy and frees it straight away.
    func prewarm() {
        guard !prewarmed, prewarmTask == nil, status == .off else { return }
        prewarmTask = Task(priority: .background) { [weak self] in
            // Out of the way of launch and the dictation model's warmup.
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.status == .off else {
                self?.prewarmTask = nil
                return
            }
            let track = LiveMeetingCaptionTrack()
            let result = await track.load()
            await track.stop()
            self.prewarmed = result == .ready
            self.prewarmTask = nil
        }
    }

    /// Loading or listening: it wants audio.
    var isActive: Bool { status == .preparing || status == .listening }

    /// Starts transcribing this recording. Clears the last meeting's text.
    func start(sessionID: UUID, shouldYield: @escaping @MainActor () -> Bool) {
        guard self.sessionID != sessionID || status == .off else { return }
        prewarmTask?.cancel()
        prewarmTask = nil
        stopTracks()
        self.sessionID = sessionID
        generation += 1
        let generation = generation
        // Turning the setting off and on again mid-meeting keeps what was said.
        if sessionID != lastLogSessionID {
            log = LiveMeetingCaptionLog()
            lastLogSessionID = sessionID
        }
        status = .preparing
        let tracks = Tracks()
        lastSequence = [:]
        // Audio queues while the models load, up to the tracks' bound.
        current.withLock { $0 = tracks }
        let yield: @Sendable () async -> Bool = { await MainActor.run { shouldYield() } }
        startTask = Task(priority: .utility) { [weak self, teardown = self.teardown] in
            await teardown?.value
            // One at a time: both tracks share one model download.
            let micLoad: LiveMeetingCaptionTrack.LoadResult = Task.isCancelled ? .failed : await tracks.microphone.load()
            let systemLoad: LiveMeetingCaptionTrack.LoadResult = Task.isCancelled ? .failed : await tracks.system.load()
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            guard micLoad == .ready, systemLoad == .ready else {
                self.status = .unavailable
                self.stopTracks()
                return
            }
            await tracks.microphone.start(shouldYield: yield) { [weak self] event, sequence in
                await MainActor.run { self?.apply(event, sequence: sequence, track: .microphone, generation: generation) }
            }
            await tracks.system.start(shouldYield: yield) { [weak self] event, sequence in
                await MainActor.run { self?.apply(event, sequence: sequence, track: .system, generation: generation) }
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
        guard !samples.isEmpty, let tracks = current.withLock({ $0 }) else { return }
        switch track {
        case .microphone: tracks.microphone.queue.append(samples)
        case .system: tracks.system.queue.append(samples)
        }
    }

    /// Stops this meeting's tracks and frees their models and buffers. Waits
    /// for an in-flight load to finish first, so a load can't put the
    /// models back after they were freed.
    private func stopTracks() {
        generation += 1
        let tracks = current.withLock { tracks in
            defer { tracks = nil }
            return tracks
        }
        let loading = startTask
        loading?.cancel()
        startTask = nil
        guard let tracks else { return }
        teardown = Task(priority: .utility) { [teardown = self.teardown] in
            await teardown?.value
            await loading?.value
            await tracks.microphone.stop()
            await tracks.system.stop()
        }
    }

    private func apply(_ event: LiveMeetingCaptionTrack.Event, sequence: Int, track: LiveMeetingTrack, generation: Int) {
        guard generation == self.generation, sequence > lastSequence[track, default: -1] else { return }
        lastSequence[track] = sequence
        switch event {
        case .partial(let text): log.setTentative(text, track: track)
        case .utterance(let text): log.commit(text, track: track)
        }
    }
}

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

    /// Where Core's live-PCM queue hands audio in, without touching the
    /// main actor.
    nonisolated static let inlet = LiveMeetingCaptionInlet()
    private var current: LiveMeetingCaptionInlet { Self.inlet }
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
    /// Skipped when the dictation preview is loading or holding the same
    /// model: that load already compiled it, and a second copy would only
    /// pay for the load again.
    func prewarm() {
        guard !prewarmed, prewarmTask == nil, status == .off else { return }
        prewarmTask = Task(priority: .background) { [weak self] in
            // Out of the way of launch and the dictation model's warmup.
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.status == .off else {
                self?.prewarmTask = nil
                return
            }
            // The dictation preview loads the same model; if it's mid-load, or
            // still waiting on the dictation model, let it settle (bounded).
            // Skip only when it ended ready (the compile is cached); if it
            // failed, prewarm as before so the first meeting isn't cold.
            let preview = LiveDictationCaptions.shared
            let outcome = await LiveTranscriptPrewarmPolicy.settle(
                state: { preview.prewarmState },
                sleep: { try? await Task.sleep(for: $0) },
                isCancelled: { Task.isCancelled }
            )
            guard outcome == .load, !Task.isCancelled else {
                self.prewarmTask = nil
                return
            }
            let track = LiveMeetingCaptionTrack()
            let result = await track.load()
            await track.stop()
            self.prewarmed = result == .ready
            self.prewarmTask = nil
        }
    }

    /// "Live transcript" was turned off: stop waiting to prewarm. The task
    /// clears itself as it exits (at once while it waits), so turning the
    /// setting back on mid-load can't start a second copy.
    func cancelPrewarm() {
        prewarmTask?.cancel()
    }

    /// Loading or listening: it wants audio.
    var isActive: Bool { status == .preparing || status == .listening }

    /// Starts transcribing this recording. Clears the last meeting's text.
    /// `shouldYield` is read by the tracks' drain loops on their own tasks;
    /// the caller keeps it current on the main actor.
    func start(sessionID: UUID, shouldYield: LiveMeetingCaptionYield) {
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
        let tracks = LiveMeetingCaptionTracks()
        lastSequence = [:]
        // Audio queues while the models load, up to the tracks' bound.
        current.tracks.withLock { $0 = tracks }
        // A lock read, not a main-actor hop: the drains poll it several
        // times a second per track.
        let yield: @Sendable () async -> Bool = { shouldYield.value }
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
                await self?.apply(event, sequence: sequence, track: .microphone, generation: generation)
            }
            await tracks.system.start(shouldYield: yield) { [weak self] event, sequence in
                await self?.apply(event, sequence: sequence, track: .system, generation: generation)
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

    /// Stops this meeting's tracks and frees their models and buffers. Waits
    /// for an in-flight load to finish first, so a load can't put the
    /// models back after they were freed.
    private func stopTracks() {
        generation += 1
        let tracks = current.tracks.withLock { tracks in
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

/// This meeting's two recognizers. A fresh pair per meeting, so a stop's
/// cleanup can never reach the next meeting's models.
struct LiveMeetingCaptionTracks: Sendable {
    let microphone = LiveMeetingCaptionTrack()
    let system = LiveMeetingCaptionTrack()
}

/// Whether the live transcript should pause for a dictation. Set on the main
/// actor when the router's recording or transcribing state changes, read by
/// the tracks' drain loops without hopping to the main actor.
final class LiveMeetingCaptionYield: Sendable {
    private let current = Mutex(false)

    var value: Bool { current.withLock { $0 } }

    func set(_ value: Bool) { current.withLock { $0 = value } }
}

/// The audio side of the live transcript, read on Core's live-PCM delivery
/// queue. Holds the current meeting's tracks, or nil when nothing runs, so
/// an idle app holds no buffers or models.
final class LiveMeetingCaptionInlet: Sendable {
    let tracks = Mutex<LiveMeetingCaptionTracks?>(nil)

    /// Called on Core's live-PCM delivery queue, never a CoreAudio callback.
    /// `samples` are 16 kHz mono.
    func offer(_ samples: [Float], track: LiveMeetingTrack) {
        guard !samples.isEmpty, let current = tracks.withLock({ $0 }) else { return }
        switch track {
        case .microphone: current.microphone.queue.append(samples)
        case .system: current.system.queue.append(samples)
        }
    }
}

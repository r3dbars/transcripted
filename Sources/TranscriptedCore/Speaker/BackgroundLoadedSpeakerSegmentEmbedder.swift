// BackgroundLoadedSpeakerSegmentEmbedder.swift
// A voiceprint model that loads off the caller's thread.
//
// Loading a Core ML voiceprint (`MLModel(contentsOf:)`, plus a GPU compile the
// first time a new build runs) takes from a fraction of a second to several. The
// app builds its meeting stack on the main actor at launch, so loading there froze
// the menubar. This wrapper knows the model's id, size and thresholds up front (so
// the host can pick the speaker database and build the diarizer with no model in
// memory) and loads the real embedder on a background queue the first time
// anything waits for it.
//
// Callers about to embed await `waitUntilLoaded()` first: `DiarizationService`
// does before it re-embeds a meeting, and `SpeakerVoiceprintMigration` before it
// moves anyone. `embed` called before the load ends blocks its thread until it
// does, so a caller that skipped the wait still gets the right model's vector
// (never nil because it was early); it must not be called on the main thread.
//
// A failed load, or a model that turns out to have a different id, size or
// thresholds, makes every `embed` return nil. The host picked the speaker
// database from this wrapper's id, so vectors from any other model must never
// reach it.

import Foundation

/// An embedder whose model loads in the background. Its `identifier`, `dimension`
/// and `thresholds` are known before the model loads.
public protocol BackgroundLoadingSpeakerSegmentEmbedder: SpeakerSegmentEmbedder {
    /// Starts the load if nothing has yet, and returns once it has ended: true
    /// when the model loaded, false when it failed (every `embed` then returns nil).
    func waitUntilLoaded() async -> Bool
}

public final class BackgroundLoadedSpeakerSegmentEmbedder: BackgroundLoadingSpeakerSegmentEmbedder, @unchecked Sendable {

    public enum LoadState: Sendable, Equatable {
        case notStarted
        case loading
        case loaded
        case failed
    }

    public let identifier: String
    public let dimension: Int
    public let thresholds: SpeakerEmbeddingThresholds

    private let loadQueue: DispatchQueue
    private let load: @Sendable () -> (any SpeakerSegmentEmbedder)?
    private let onLoadEnded: (@Sendable (Bool) -> Void)?

    private let condition = NSCondition()
    private var state: LoadState = .notStarted
    private var loaded: (any SpeakerSegmentEmbedder)?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    /// - Parameters:
    ///   - identifier, dimension, thresholds: what `load` must produce. The host
    ///     keys the speaker database on these before the model loads.
    ///   - loadQueue: where `load` runs. Never the caller's thread.
    ///   - onLoadEnded: called once, on `loadQueue`, with whether the model loaded.
    ///   - load: builds the real embedder; nil when it can't.
    public init(
        identifier: String,
        dimension: Int,
        thresholds: SpeakerEmbeddingThresholds,
        loadQueue: DispatchQueue = .global(qos: .utility),
        onLoadEnded: (@Sendable (Bool) -> Void)? = nil,
        load: @escaping @Sendable () -> (any SpeakerSegmentEmbedder)?
    ) {
        self.identifier = identifier
        self.dimension = dimension
        self.thresholds = thresholds
        self.loadQueue = loadQueue
        self.onLoadEnded = onLoadEnded
        self.load = load
    }

    public var loadState: LoadState {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    /// Starts the load on `loadQueue` if nothing has yet. Returns at once.
    public func startLoading() {
        condition.lock()
        defer { condition.unlock() }
        startLoadingLocked()
    }

    public func waitUntilLoaded() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            condition.lock()
            startLoadingLocked()
            switch state {
            case .loaded:
                condition.unlock()
                continuation.resume(returning: true)
            case .failed:
                condition.unlock()
                continuation.resume(returning: false)
            case .notStarted, .loading:
                waiters.append(continuation)
                condition.unlock()
            }
        }
    }

    public func embed(samples: [Float], sampleRate: Int) -> [Float]? {
        loadedEmbedderBlocking()?.embed(samples: samples, sampleRate: sampleRate)
    }

    /// Starts the first load if nothing has yet (that load warms the model by
    /// itself); once loaded, passes the prewarm on. Never waits for a load.
    public func prewarm() {
        condition.lock()
        startLoadingLocked()
        let ready = state == .loaded ? loaded : nil
        condition.unlock()
        ready?.prewarm()
    }

    // MARK: - Loading

    private func startLoadingLocked() {
        guard state == .notStarted else { return }
        state = .loading
        loadQueue.async { [self] in
            let candidate = load()
            let usable = candidate.flatMap { matchesDeclaredModel($0) ? $0 : nil }
            if candidate != nil, usable == nil {
                AppLogger.speakers.error("Background voiceprint model does not match its declared id, size or thresholds", [
                    "embedder": identifier,
                ])
            }
            condition.lock()
            loaded = usable
            state = usable == nil ? .failed : .loaded
            let released = waiters
            waiters.removeAll()
            condition.broadcast()
            condition.unlock()
            onLoadEnded?(usable != nil)
            released.forEach { $0.resume(returning: usable != nil) }
        }
    }

    private func matchesDeclaredModel(_ candidate: any SpeakerSegmentEmbedder) -> Bool {
        candidate.identifier == identifier
            && candidate.dimension == dimension
            && candidate.thresholds == thresholds
    }

    /// The loaded embedder, waiting on this thread for a load in flight.
    private func loadedEmbedderBlocking() -> (any SpeakerSegmentEmbedder)? {
        condition.lock()
        defer { condition.unlock() }
        startLoadingLocked()
        while state == .loading {
            condition.wait()
        }
        return loaded
    }
}

extension BackgroundLoadedSpeakerSegmentEmbedder: SpeakerSegmentLengthPrewarming {
    /// Passes a warm-up for known turn lengths to the loaded model. Does nothing
    /// before the load ends; never waits for it.
    public func prewarm(sampleCounts: [Int]) {
        condition.lock()
        let ready = state == .loaded ? loaded : nil
        condition.unlock()
        (ready as? any SpeakerSegmentLengthPrewarming)?.prewarm(sampleCounts: sampleCounts)
    }
}

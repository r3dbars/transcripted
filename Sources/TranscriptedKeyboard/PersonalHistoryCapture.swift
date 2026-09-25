#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Bounded, memory-only batching on the keyboard side. The key callback only
/// snapshots the local consent policy and enqueues a small value; event
/// creation and authenticated socket I/O happen later on a utility queue. The
/// Tilde app owns every disk write.
final class PersonalHistoryCapture: @unchecked Sendable {
    static let shared = PersonalHistoryCapture()

    private static let defaultMaximumBufferedEvents = 192
    private static let maximumDiscardedStreams = 192
    private static let flushDelay: TimeInterval = 0.75
    private static let retryDelay: TimeInterval = 5
    /// Transcripted: how many times the app may refuse an event before it's
    /// dropped (about a minute of retries at `retryDelay`).
    static let maximumRefusedAttempts = 12

    private let queue = DispatchQueue(label: "com.justinbetker.draft.inputmethod.personal-history", qos: .utility)
    private let defaults: UserDefaults
    private let policy = PersonalHistoryCapturePolicy()
    private let appScope: WritingAppScopeReader
    private let now: @Sendable () -> Date
    private let sender: @Sendable ([PersonalHistoryEvent]) async -> GhostBrainResponse
    private let maximumBufferedEvents: Int
    private var pending: [PersonalHistoryEvent] = []
    private var scheduledFlush: DispatchWorkItem?
    private var sending = false
    private var attemptedEventIDs: Set<String> = []
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var discardedStreams: Set<StreamIdentity> = []
    private var discardedStreamOrder: [StreamIdentity] = []
    /// Transcripted: how many times the app has refused each event still
    /// waiting to be sent again.
    private var refusals: [String: Int] = [:]

    struct Permit: Sendable {
        let appBundleIdentifier: String
        let timestampMilliseconds: Int64
        let historyIdentifier: String
        let consentIdentifier: String
    }

    private struct CaptureEnvelope: Sendable {
        let text: String
        let source: PersonalHistoryEventSource
        let sessionIdentifier: String
        let permit: Permit
    }

    private struct StreamIdentity: Hashable {
        let historyIdentifier: String
        let consentIdentifier: String
        let sessionIdentifier: String
        let appBundleIdentifier: String

        init(_ event: PersonalHistoryEvent) {
            historyIdentifier = event.historyIdentifier
            consentIdentifier = event.consentIdentifier
            sessionIdentifier = event.sessionIdentifier
            appBundleIdentifier = event.appBundleIdentifier
        }
    }

    init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        maximumBufferedEvents: Int = PersonalHistoryCapture.defaultMaximumBufferedEvents,
        sender: @escaping @Sendable ([PersonalHistoryEvent]) async -> GhostBrainResponse = {
            await GhostBrainClient.recordPersonalHistory($0)
        }
    ) {
        self.defaults = defaults
        self.appScope = WritingAppScopeReader(defaults: defaults)
        self.now = now
        self.maximumBufferedEvents = max(1, maximumBufferedEvents)
        self.sender = sender
    }

    func permit(
        appBundleIdentifier: String?,
        secureInput: Bool
    ) -> Permit? {
        // Snapshot consent and generation before leaving the key callback. A
        // delayed pre-deletion key must never be relabeled into a new history.
        if secureInput {
            sensitiveInputBegan()
            return nil
        }
        guard defaults.bool(forKey: PersonalHistorySettingsContract.enabledKey),
              let historyIdentifier = defaults.string(
                forKey: PersonalHistorySettingsContract.historyIdentifierKey
              ),
              let consentIdentifier = defaults.string(
                forKey: PersonalHistorySettingsContract.consentIdentifierKey
              ),
              case let .allowed(app) = policy.decision(
                enabled: true,
                secureInput: secureInput,
                appBundleIdentifier: appBundleIdentifier,
                excludedApps: Set(defaults.stringArray(
                    forKey: PersonalHistorySettingsContract.excludedAppsKey
                ) ?? []),
                appScope: appScope.current()
              ) else { return nil }
        return Permit(
            appBundleIdentifier: app,
            timestampMilliseconds: Int64(now().timeIntervalSince1970 * 1_000),
            historyIdentifier: historyIdentifier,
            consentIdentifier: consentIdentifier
        )
    }

    func record(
        text: String,
        source: PersonalHistoryEventSource,
        sessionIdentifier: String,
        permit: Permit
    ) {
        let envelope = CaptureEnvelope(
            text: text,
            source: source,
            sessionIdentifier: sessionIdentifier,
            permit: permit
        )
        queue.async { [self] in
            recordOnQueue(envelope)
        }
    }

    /// Transcripted: Backspace removed `characters` of the keyboard's own
    /// text at the end of this segment chain. Text-free; queued like typing.
    func recordDeletion(
        characters: Int,
        sessionIdentifier: String,
        permit: Permit
    ) {
        queue.async { [self] in
            guard let event = PersonalHistoryEvent(
                deletionID: UUID().uuidString,
                timestampMilliseconds: permit.timestampMilliseconds,
                historyIdentifier: permit.historyIdentifier,
                consentIdentifier: permit.consentIdentifier,
                sessionIdentifier: sessionIdentifier,
                appBundleIdentifier: permit.appBundleIdentifier,
                deletedCharacters: characters
            ) else { return }
            recordEventOnQueue(event)
        }
    }

    private func recordOnQueue(_ envelope: CaptureEnvelope) {
        guard let event = PersonalHistoryEvent(
            id: UUID().uuidString,
            timestampMilliseconds: envelope.permit.timestampMilliseconds,
            historyIdentifier: envelope.permit.historyIdentifier,
            consentIdentifier: envelope.permit.consentIdentifier,
            sessionIdentifier: envelope.sessionIdentifier,
            appBundleIdentifier: envelope.permit.appBundleIdentifier,
            source: envelope.source,
            text: envelope.text
        ) else { return }
        recordEventOnQueue(event)
    }

    private func recordEventOnQueue(_ event: PersonalHistoryEvent) {
        guard !discardedStreams.contains(StreamIdentity(event)) else { return }
        if event.source == .typed || event.source == .deletion,
           let lastIndex = pending.indices.last,
           !attemptedEventIDs.contains(pending[lastIndex].id),
           let combined = event.source == .deletion
               ? pending[lastIndex].coalescingDeletion(with: event)
               : pending[lastIndex].coalescing(with: event) {
            pending[lastIndex] = combined
        } else {
            pending.append(event)
        }
        if pending.count > maximumBufferedEvents {
            while pending.count > maximumBufferedEvents,
                  let index = pending.firstIndex(where: {
                      !attemptedEventIDs.contains($0.id)
                  }) {
                let stream = StreamIdentity(pending[index])
                discard(stream)
                pending.removeAll {
                    StreamIdentity($0) == stream
                        && !attemptedEventIDs.contains($0.id)
                }
            }
            retainAttemptedIDsStillPending()
        }
        scheduleFlush(after: Self.flushDelay)
    }

    func flush() {
        queue.async { [self] in scheduleFlush(after: 0) }
    }

    func flushAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                scheduledFlush?.cancel()
                scheduledFlush = nil
                sendWaiters.append(continuation)
                sendNextBatch()
                if !sending { resumeSendWaiters() }
            }
        }
    }

    func sensitiveInputBegan() {
        queue.async { [self] in
            scheduledFlush?.cancel()
            scheduledFlush = nil
            pending.removeAll(keepingCapacity: true)
            attemptedEventIDs.removeAll(keepingCapacity: true)
            discardedStreams.removeAll(keepingCapacity: true)
            discardedStreamOrder.removeAll(keepingCapacity: true)
        }
    }

    private func scheduleFlush(after delay: TimeInterval) {
        guard !pending.isEmpty else { return }
        scheduledFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendNextBatch() }
        scheduledFlush = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func sendNextBatch() {
        guard !sending, !pending.isEmpty else { return }
        guard defaults.bool(forKey: PersonalHistorySettingsContract.enabledKey),
              let historyIdentifier = defaults.string(
                forKey: PersonalHistorySettingsContract.historyIdentifierKey
              ),
              let consentIdentifier = defaults.string(
                forKey: PersonalHistorySettingsContract.consentIdentifierKey
              ) else {
            pending.removeAll(keepingCapacity: true)
            attemptedEventIDs.removeAll(keepingCapacity: true)
            return
        }
        let excluded = Set(defaults.stringArray(
            forKey: PersonalHistorySettingsContract.excludedAppsKey
        ) ?? [])
        let scope = appScope.current()
        pending.removeAll {
            $0.historyIdentifier != historyIdentifier
                || $0.consentIdentifier != consentIdentifier
                || excluded.contains($0.appBundleIdentifier)
                || !scope.includes($0.appBundleIdentifier)
        }
        retainAttemptedIDsStillPending()
        guard !pending.isEmpty else { return }
        sending = true
        var batch = PersonalHistoryEvent.boundedBatchPrefix(pending)
        while !batch.isEmpty, !GhostBrainClient.personalHistoryPayloadFits(batch) {
            batch.removeLast()
        }
        guard !batch.isEmpty else {
            pending.removeFirst()
            retainAttemptedIDsStillPending()
            sending = false
            scheduleFlush(after: pending.isEmpty ? 0 : Self.flushDelay)
            return
        }
        let sentIDs = Set(batch.map(\.id))
        attemptedEventIDs.formUnion(sentIDs)

        Task { [weak self] in
            guard let self else { return }
            let response = await self.sender(batch)
            self.queue.async { [weak self] in
                guard let self else { return }
                sending = false
                if response == .recorded {
                    pending.removeAll { sentIDs.contains($0.id) }
                    attemptedEventIDs.subtract(sentIDs)
                    scheduleFlush(after: pending.isEmpty ? 0 : Self.flushDelay)
                } else if let dropped = Self.rejectedEventIDs(in: response, sent: sentIDs)
                    ?? exhaustedAfterRefusal(response, sent: sentIDs) {
                    // Transcripted: events the app can't read (it's older
                    // than this keyboard), or ones it refused 12 times, are
                    // dropped so the text behind them can go. Tilde retried
                    // a refused batch forever. The rest of the batch goes again.
                    pending.removeAll { dropped.contains($0.id) }
                    retainAttemptedIDsStillPending()
                    scheduleFlush(after: pending.isEmpty ? 0 : Self.flushDelay)
                } else {
                    scheduleFlush(after: Self.retryDelay)
                }
                refusals = refusals.filter { self.attemptedEventIDs.contains($0.key) }
                resumeSendWaiters()
            }
        }
    }

    /// Transcripted: the IDs an `unsupported` answer names that were in the
    /// batch. `nil` for any other answer, or one naming none of them.
    private static func rejectedEventIDs(in response: GhostBrainResponse, sent: Set<String>) -> Set<String>? {
        guard response.outcome == .unsupported,
              let rejected = response.rejectedEventIDs.map({ sent.intersection($0) }),
              !rejected.isEmpty else { return nil }
        return rejected
    }

    /// Transcripted: counts a refusal of every sent event when the app
    /// answered without recording the batch, and returns the events refused
    /// `maximumRefusedAttempts` times (`nil` when none are). Not reaching
    /// the app (`unavailable`, `timeout`) isn't a refusal; that retries as
    /// long as Tilde's did.
    private func exhaustedAfterRefusal(_ response: GhostBrainResponse, sent: Set<String>) -> Set<String>? {
        guard response.outcome != .unavailable, response.outcome != .timeout else { return nil }
        var exhausted: Set<String> = []
        for id in sent {
            let count = refusals[id, default: 0] + 1
            refusals[id] = count
            if count >= Self.maximumRefusedAttempts { exhausted.insert(id) }
        }
        return exhausted.isEmpty ? nil : exhausted
    }

    private func retainAttemptedIDsStillPending() {
        attemptedEventIDs.formIntersection(Set(pending.map(\.id)))
    }

    private func resumeSendWaiters() {
        let waiters = sendWaiters
        sendWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }

    private func discard(_ stream: StreamIdentity) {
        guard discardedStreams.insert(stream).inserted else { return }
        if discardedStreamOrder.count == Self.maximumDiscardedStreams {
            discardedStreams.remove(discardedStreamOrder.removeFirst())
        }
        discardedStreamOrder.append(stream)
    }
}

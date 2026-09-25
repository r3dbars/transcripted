#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

protocol PersonalHistoryIngesting: Sendable {
    func ingest(_ events: [PersonalHistoryEvent]) async -> Bool
}

enum PersonalNextWordShadowPhase: Equatable, Sendable {
    case inactive
    case loading
    case ready
    case unavailable
}

struct PersonalNextWordShadowStatus: Equatable, Sendable {
    static let reportingOpportunityMinimum = 2_000
    static let reportingPredictionMinimum = 200
    static let reportingDisagreementMinimum = 100
    static let reportingActiveDayMinimum = 14

    let phase: PersonalNextWordShadowPhase
    let snapshot: PersonalNextWordShadowSnapshot

    var menuLine: String {
        let capacity = snapshot.capacityLimited ? " · memory limit reached" : ""
        let shadowOnly = " · shadow-only"
        switch phase {
        case .inactive:
            return "Next-word test: off\(shadowOnly)"
        case .loading:
            return "Next-word test: loading recent history…\(shadowOnly)"
        case .unavailable:
            return "Next-word test: unavailable\(shadowOnly)"
        case .ready where !isDescriptive:
            let words = "\(snapshot.opportunities.formatted())/2,000 shared fresh words"
            let predictions = "\(snapshot.predictions)/\(Self.reportingPredictionMinimum) candidate predictions"
            let differences = "\(snapshot.predictionDisagreements)/\(Self.reportingDisagreementMinimum) disagreements"
            let days = "\(snapshot.activeDays)/\(Self.reportingActiveDayMinimum) active days"
            return "Next-word test: \(words) · \(predictions) · \(differences) · \(days)\(capacity)\(shadowOnly)"
        case .ready:
            let candidate = Self.percent(snapshot.exactHits, of: snapshot.opportunities)
            let baseline = Self.percent(snapshot.baselineExactHits, of: snapshot.opportunities)
            return "Next-word test: candidate \(candidate) vs baseline \(baseline) effective · \(snapshot.opportunities.formatted()) shared fresh words\(capacity)\(shadowOnly)"
        }
    }

    private var isDescriptive: Bool {
        snapshot.opportunities >= Self.reportingOpportunityMinimum
            && snapshot.predictions >= Self.reportingPredictionMinimum
            && snapshot.predictionDisagreements >= Self.reportingDisagreementMinimum
            && snapshot.activeDays >= Self.reportingActiveDayMinimum
    }

    private static func percent(_ hits: Int, of opportunities: Int) -> String {
        guard opportunities > 0 else { return "0.0%" }
        return String(format: "%.1f%%", Double(hits) * 100 / Double(opportunities))
    }
}

enum PersonalHistoryStorageHealth: String, Equatable, Sendable {
    case healthy
    case storeCorrupt = "store-corrupt"
    case keyUnavailable = "key-unavailable"
    case storageUnavailable = "storage-unavailable"
    case internalError = "internal-error"

    static func failure(error: any Error, duringReplay: Bool = false) -> Self? {
        guard let storageError = error as? PersonalHistoryStorageError else {
            if error is CocoaError || error is POSIXError { return .storageUnavailable }
            return duringReplay ? nil : .internalError
        }
        switch storageError {
        case .corruptStore: return .storeCorrupt
        case .invalidKey, .missingKey: return .keyUnavailable
        case .keychain: return .storageUnavailable
        case .invalidEvent: return duringReplay ? nil : .internalError
        }
    }

    var menuLine: String? {
        switch self {
        case .healthy: return nil
        case .storeCorrupt, .keyUnavailable: return "History: not saving — reset required"
        case .storageUnavailable: return "History: not saving — storage unavailable"
        case .internalError: return "History: not saving — restart Tilde"
        }
    }
}

private final class PersonalHistoryStorageHealthState: @unchecked Sendable {
    private let lock = NSLock()
    private let diagnostics: DiagnosticsLog
    private var health = PersonalHistoryStorageHealth.healthy

    init(diagnostics: DiagnosticsLog) { self.diagnostics = diagnostics }

    func snapshot() -> PersonalHistoryStorageHealth { lock.withLock { health } }

    func recordFailure(_ error: any Error, duringReplay: Bool = false) {
        guard let next = PersonalHistoryStorageHealth.failure(
            error: error,
            duringReplay: duringReplay
        ) else { return }
        record(next)
    }

    func recordSuccess() { record(.healthy) }
    func reset() { lock.withLock { health = .healthy } }

    private func record(_ next: PersonalHistoryStorageHealth) {
        let changed = lock.withLock {
            guard health != next else { return false }
            health = next
            return true
        }
        guard changed else { return }
        if next == .healthy {
            diagnostics.record("personal-history-write-recovered")
        } else {
            diagnostics.record("personal-history-write-failed", metadata: ["reason": next.rawValue])
        }
    }
}

private struct PersonalHistoryConfiguration: Equatable, Sendable {
    let revision: Int
    let enabled: Bool
    let excludedApps: Set<String>
    let consentIdentifier: String
    let experimentIdentifier: String
}

private final class PersonalHistoryConfigurationState: @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: PersonalHistoryConfiguration

    init(
        enabled: Bool,
        excludedApps: Set<String>,
        consentIdentifier: String,
        experimentIdentifier: String
    ) {
        configuration = PersonalHistoryConfiguration(
            revision: 1,
            enabled: enabled,
            excludedApps: excludedApps,
            consentIdentifier: consentIdentifier,
            experimentIdentifier: experimentIdentifier
        )
    }

    func snapshot() -> PersonalHistoryConfiguration {
        lock.withLock { configuration }
    }

    func update(
        enabled: Bool,
        excludedApps: Set<String>,
        rotateExperiment: Bool = false
    ) -> PersonalHistoryConfiguration {
        lock.withLock {
            configuration = PersonalHistoryConfiguration(
                revision: configuration.revision + 1,
                enabled: enabled,
                excludedApps: excludedApps,
                consentIdentifier: UUID().uuidString,
                experimentIdentifier: rotateExperiment
                    ? UUID().uuidString
                    : configuration.experimentIdentifier
            )
            return configuration
        }
    }
}

struct OrderedAsyncTaskTail: Sendable {
    private var tail: Task<Void, Never>?

    mutating func enqueue<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) -> Task<Value, Error> {
        let predecessor = tail
        let current = Task {
            if let predecessor { await predecessor.value }
            return try await operation()
        }
        tail = Task { _ = await current.result }
        return current
    }
}

final class PersonalHistoryController: PersonalHistoryIngesting, @unchecked Sendable {
    /// How often the trained table is written back. It is a whole-file
    /// record — hundreds of kilobytes on a well-trained model — so writing
    /// it on every keystroke batch would be pointless churn. Staleness is
    /// safe rather than lossy because the saved model names the log position
    /// it covers and the next launch replays only what came after, so this
    /// number trades disk writes against replay work, never against learning.
    static let defaultModelPersistenceInterval: TimeInterval = 20

    private let store: any PersonalHistoryStore
    private let settings: TildeSettings
    private let operations: PersistenceOperations
    private let configurationState: PersonalHistoryConfigurationState
    private let storageHealthState: PersonalHistoryStorageHealthState

    init(
        store: any PersonalHistoryStore = EncryptedPersonalHistoryStore(),
        settings: TildeSettings = TildeSettings(),
        diagnostics: DiagnosticsLog = .shared,
        modelPersistenceInterval: TimeInterval
            = PersonalHistoryController.defaultModelPersistenceInterval
    ) {
        self.store = store
        self.settings = settings
        let storageHealthState = PersonalHistoryStorageHealthState(diagnostics: diagnostics)
        self.storageHealthState = storageHealthState
        let consentIdentifier = settings.personalHistoryConsentIdentifier ?? UUID().uuidString
        settings.personalHistoryConsentIdentifier = consentIdentifier
        let initialConfiguration = PersonalHistoryConfigurationState(
            enabled: settings.personalHistoryEnabled,
            excludedApps: settings.personalHistoryExcludedApps,
            consentIdentifier: consentIdentifier,
            experimentIdentifier: settings.personalNextWordExperimentIdentifier
                ?? UUID().uuidString
        )
        settings.personalNextWordExperimentIdentifier = initialConfiguration.snapshot()
            .experimentIdentifier
        self.configurationState = initialConfiguration
        let historyIdentifier = settings.personalHistoryIdentifier ?? UUID().uuidString
        settings.personalHistoryIdentifier = historyIdentifier
        self.operations = PersistenceOperations(
            store: store,
            historyIdentifier: historyIdentifier,
            configurationState: initialConfiguration,
            storageHealthState: storageHealthState,
            diagnostics: diagnostics,
            modelPersistenceInterval: modelPersistenceInterval
        )
        let configuration = initialConfiguration.snapshot()
        if configuration.enabled {
            scheduleConfiguration(configuration)
        }
    }

    var isEnabled: Bool {
        get { settings.personalHistoryEnabled }
        set {
            let configuration = configurationState.update(
                enabled: newValue,
                excludedApps: settings.personalHistoryExcludedApps
            )
            settings.personalHistoryConsentIdentifier = configuration.consentIdentifier
            settings.personalHistoryEnabled = newValue
            scheduleConfiguration(configuration)
        }
    }

    var excludedApps: Set<String> {
        get { settings.personalHistoryExcludedApps }
        set {
            let normalized = Set(PersonalHistoryCapturePolicy.normalizedExcludedApps(newValue))
            let configuration = configurationState.update(
                enabled: settings.personalHistoryEnabled,
                excludedApps: normalized,
                rotateExperiment: true
            )
            settings.personalHistoryConsentIdentifier = configuration.consentIdentifier
            settings.personalNextWordExperimentIdentifier = configuration.experimentIdentifier
            settings.personalHistoryExcludedApps = normalized
            scheduleConfiguration(configuration)
        }
    }

    var location: URL { store.location }

    var storageHealthSnapshot: PersonalHistoryStorageHealth { storageHealthState.snapshot() }

    func ingest(_ events: [PersonalHistoryEvent]) async -> Bool {
        guard PersonalHistoryEvent.validBatch(events) else { return false }
        // Transcripted: Backspace counts are for Save my writing's day files.
        // The encrypted log and the predictor get exactly Tilde's events.
        let events = events.filter { $0.source != .deletion }
        guard !events.isEmpty else { return true }
        let configuration = configurationState.snapshot()
        do {
            try await operations.ingest(events, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    func summary() async -> PersonalHistorySummary? {
        try? await store.summary()
    }

    /// Read-only production lookup for the "Personal suggestions
    /// (experimental)" toggle (`docs/plans/road-to-paid.md` Phase 3). Goes
    /// through the SAME actor that owns the live trained model — no new
    /// state, no separate copy — but only ever calls
    /// `PersonalNextWordShadow.predictNextWord`, a non-mutating lookup, so
    /// it can never perturb `nextWordStatus`'s paired shadow scoring.
    /// Per-app exclusions gate this exactly like they gate capture (the
    /// covenant): an excluded or missing app, or the feature/master toggle
    /// being off, always returns `nil` — the caller then serves the base
    /// ghost untouched.
    func personalNextWordPrediction(
        afterTailWords tailWords: [String],
        appBundleIdentifier: String?
    ) async -> PersonalNextWordPrediction? {
        let configuration = configurationState.snapshot()
        guard configuration.enabled,
              let appBundleIdentifier, PersonalHistoryEvent.validBundleIdentifier(appBundleIdentifier),
              !configuration.excludedApps.contains(appBundleIdentifier) else { return nil }
        return await operations.predictNextWord(afterTailWords: tailWords, configuration: configuration)
    }

    func nextWordStatus() async -> PersonalNextWordShadowStatus {
        let configuration = configurationState.snapshot()
        let status = await operations.nextWordStatus(configuration: configuration)
        guard configuration.enabled else {
            return PersonalNextWordShadowStatus(
                phase: .inactive,
                snapshot: PersonalNextWordShadow().snapshot
            )
        }
        return status.phase == .inactive
            ? PersonalNextWordShadowStatus(phase: .loading, snapshot: status.snapshot)
            : status
    }

    private func scheduleConfiguration(_ configuration: PersonalHistoryConfiguration) {
        Task {
            await operations.configure(configuration)
        }
    }

    func deleteAll() async throws {
        let configuration = configurationState.update(
            enabled: false,
            excludedApps: settings.personalHistoryExcludedApps,
            rotateExperiment: true
        )
        settings.personalHistoryConsentIdentifier = configuration.consentIdentifier
        settings.personalNextWordExperimentIdentifier = configuration.experimentIdentifier
        settings.personalHistoryEnabled = false
        let nextIdentifier = UUID().uuidString
        settings.personalHistoryIdentifier = nextIdentifier
        try await operations.deleteAll(
            nextHistoryIdentifier: nextIdentifier,
            configuration: configuration
        )
        if configurationState.snapshot() == configuration,
           settings.personalHistoryIdentifier == nextIdentifier {
            storageHealthState.reset()
        }
    }
}

private actor PersistenceOperations {
    private static let maximumReplayBytes: Int64 = 4 * 1_024 * 1_024
    private static let maximumReplayBacklogEvents = 192

    private let store: any PersonalHistoryStore
    private let configurationState: PersonalHistoryConfigurationState
    private let storageHealthState: PersonalHistoryStorageHealthState
    private let diagnostics: DiagnosticsLog
    private let modelPersistenceInterval: TimeInterval
    private var historyIdentifier: String
    private var nextWord = PersonalNextWordShadow()
    private var nextWordPhase: PersonalNextWordShadowPhase = .inactive
    private var configurationRevision = 0
    private var replayBacklog: [PersonalHistoryEvent] = []
    private var replayBacklogOverflowed = false
    private var ingestOperations = OrderedAsyncTaskTail()
    private var storageOperations = OrderedAsyncTaskTail()
    /// The newest log position this process has written. `nextWord` has
    /// consumed every record up to it, so it is exactly the coverage a saved
    /// trained table may claim.
    private var lastAppendedSequence: Int64 = 0
    private var lastModelSaveUptime: TimeInterval?
    private var modelSaveFailing = false

    init(
        store: any PersonalHistoryStore,
        historyIdentifier: String,
        configurationState: PersonalHistoryConfigurationState,
        storageHealthState: PersonalHistoryStorageHealthState,
        diagnostics: DiagnosticsLog,
        modelPersistenceInterval: TimeInterval
    ) {
        self.store = store
        self.historyIdentifier = historyIdentifier
        self.configurationState = configurationState
        self.storageHealthState = storageHealthState
        self.diagnostics = diagnostics
        self.modelPersistenceInterval = modelPersistenceInterval
    }

    func ingest(
        _ events: [PersonalHistoryEvent],
        configuration: PersonalHistoryConfiguration
    ) async throws {
        let transaction = ingestOperations.enqueue { [weak self] in
            guard let self else { return }
            try await self.ingestSerially(events, configuration: configuration)
        }
        try await transaction.value
    }

    private func ingestSerially(
        _ events: [PersonalHistoryEvent],
        configuration: PersonalHistoryConfiguration
    ) async throws {
        guard events.allSatisfy({ $0.historyIdentifier == historyIdentifier }) else {
            return
        }
        guard configuration.enabled,
              configurationState.snapshot() == configuration else { return }
        let allowed = events.filter {
            $0.consentIdentifier == configuration.consentIdentifier
                && !DefaultExcludedApps.isExcluded($0.appBundleIdentifier, configuredExcludedApps: configuration.excludedApps)
        }
        guard !allowed.isEmpty else { return }

        var evaluated: PersonalNextWordShadow?
        var storedCheckpoint: PersonalNextWordStoredCheckpoint?
        if configurationRevision == configuration.revision, nextWordPhase == .ready {
            var updated = nextWord
            updated.consume(allowed, scoring: true)
            evaluated = updated
            storedCheckpoint = PersonalNextWordStoredCheckpoint(
                historyIdentifier: historyIdentifier,
                experimentIdentifier: configuration.experimentIdentifier,
                excludedApps: configuration.excludedApps,
                checkpoint: updated.checkpoint
            )
        }

        let store = store
        let checkpointToStore = storedCheckpoint
        let append = storageOperations.enqueue {
            try await store.append(allowed, checkpoint: checkpointToStore)
        }
        let appendedSequence: Int64
        do {
            appendedSequence = try await append.value
            guard configurationState.snapshot() == configuration else { return }
            storageHealthState.recordSuccess()
        } catch {
            guard configurationState.snapshot() == configuration else { throw error }
            storageHealthState.recordFailure(error)
            throw error
        }
        lastAppendedSequence = max(lastAppendedSequence, appendedSequence)

        guard configurationState.snapshot() == configuration else { return }
        if configuration.revision > configurationRevision {
            beginConfiguration(configuration)
            return
        }
        guard configurationRevision == configuration.revision else { return }
        switch nextWordPhase {
        case .loading:
            replayBacklog.append(contentsOf: allowed)
            if replayBacklog.count > Self.maximumReplayBacklogEvents {
                replayBacklog.removeAll(keepingCapacity: true)
                replayBacklogOverflowed = true
                nextWordPhase = .unavailable
            }
        case .ready:
            if let evaluated {
                nextWord = evaluated
            } else {
                // The replay may have finished while this loading-phase append
                // was in flight. Warm from the durable batch without scoring it.
                nextWord.consume(allowed, scoring: false)
            }
            await persistTrainedModelIfDue(configuration: configuration)
        case .inactive:
            break
        case .unavailable:
            break
        }
    }

    /// Writes the trained table back into the encrypted store, throttled.
    /// `nextWord` has now consumed every record up to `lastAppendedSequence`,
    /// so that is exactly the coverage the saved model may claim.
    ///
    /// A failed save never fails the ingest — the events themselves are
    /// already durable, and the model is derived state that a replay can
    /// rebuild. It stays legible as its own count-only diagnostic rather
    /// than as "History: not saving", which would be untrue.
    private func persistTrainedModelIfDue(
        configuration: PersonalHistoryConfiguration
    ) async {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastModelSaveUptime,
           now - lastModelSaveUptime < modelPersistenceInterval,
           now >= lastModelSaveUptime {
            return
        }
        lastModelSaveUptime = now
        let coverage = lastAppendedSequence
        let stored = PersonalNextWordStoredModel(
            historyIdentifier: historyIdentifier,
            experimentIdentifier: configuration.experimentIdentifier,
            excludedApps: configuration.excludedApps,
            coveredThroughSequence: coverage,
            model: nextWord.trainedModel
        )
        let store = store
        let save = storageOperations.enqueue { try await store.saveTrainedModel(stored) }
        do {
            try await save.value
            guard configurationState.snapshot() == configuration else { return }
            if modelSaveFailing {
                modelSaveFailing = false
                diagnostics.record("personal-model-save-recovered")
            }
        } catch {
            guard configurationState.snapshot() == configuration, !modelSaveFailing else { return }
            modelSaveFailing = true
            diagnostics.record(
                "personal-model-save-failed",
                metadata: ["reason": PersonalHistoryStorageHealth.failure(error: error)?.rawValue
                    ?? "internal-error"]
            )
        }
    }

    func configure(_ configuration: PersonalHistoryConfiguration) {
        guard configuration.revision > configurationRevision else { return }
        beginConfiguration(configuration)
    }

    private func beginConfiguration(_ configuration: PersonalHistoryConfiguration) {
        configurationRevision = configuration.revision
        replayBacklog.removeAll(keepingCapacity: true)
        replayBacklogOverflowed = false
        nextWord.reset()
        nextWordPhase = configuration.enabled ? .loading : .inactive
        guard configuration.enabled else { return }

        let store = store
        Task { [weak self] in
            do {
                let replay = try await store.loadReplay(maximumBytes: Self.maximumReplayBytes)
                await self?.finishReplay(replay, configuration: configuration)
            } catch {
                await self?.failReplay(error, configuration: configuration)
            }
        }
    }

    private func finishReplay(
        _ replay: PersonalHistoryReplay,
        configuration: PersonalHistoryConfiguration
    ) {
        guard configurationRevision == configuration.revision,
              configurationState.snapshot() == configuration,
              !replayBacklogOverflowed else { return }
        let stored = replay.checkpoint?.matches(
            historyIdentifier: historyIdentifier,
            experimentIdentifier: configuration.experimentIdentifier,
            excludedApps: configuration.excludedApps
        ) == true ? replay.checkpoint : nil
        var rebuilt = stored.flatMap { PersonalNextWordShadow(checkpoint: $0.checkpoint) }
            ?? PersonalNextWordShadow()
        // The trained table, when one was saved under this exact scope, is
        // put back instead of being relearned from a bounded tail of raw
        // history — which is what used to silently reset learning on every
        // launch. It names the log position it already accounts for, so the
        // replay below picks up exactly the records written after it: a
        // restore followed by that catch-up is the same model a full rebuild
        // would have produced.
        let storedModel = replay.trainedModel?.matches(
            historyIdentifier: historyIdentifier,
            experimentIdentifier: configuration.experimentIdentifier,
            excludedApps: configuration.excludedApps
        ) == true ? replay.trainedModel : nil
        var coverage: Int64?
        if let storedModel, rebuilt.restore(storedModel.model) {
            coverage = storedModel.coveredThroughSequence
        }
        // With nothing restored every record replays, including the ones
        // written before log positions existed (they decode as position 0
        // and a `> 0` filter would silently drop a whole pre-upgrade history).
        let events = (coverage.map(replay.events(after:)) ?? replay.events).filter {
            $0.historyIdentifier == historyIdentifier
                && !DefaultExcludedApps.isExcluded($0.appBundleIdentifier, configuredExcludedApps: configuration.excludedApps)
        }
        rebuilt.consume(events, scoring: false)
        rebuilt.consume(replayBacklog, scoring: false)
        guard configurationRevision == configuration.revision,
              configurationState.snapshot() == configuration else { return }
        replayBacklog.removeAll(keepingCapacity: true)
        lastAppendedSequence = max(
            lastAppendedSequence,
            replay.records.map(\.sequence).max() ?? 0
        )
        nextWord = rebuilt
        nextWordPhase = .ready
    }

    private func failReplay(
        _ error: any Error,
        configuration: PersonalHistoryConfiguration
    ) {
        guard configurationRevision == configuration.revision,
              configurationState.snapshot() == configuration else { return }
        storageHealthState.recordFailure(error, duringReplay: true)
        replayBacklog.removeAll(keepingCapacity: true)
        nextWord.reset()
        nextWordPhase = .unavailable
    }

    /// Non-mutating: `nextWord.predictNextWord` reads `model` only, so this
    /// leaves `nextWord`, `nextWordPhase`, `totals`, and `days` exactly as
    /// they were — the paired shadow experiment's own scoring
    /// (`nextWordStatus`) is unaffected by whether or how often this is
    /// called.
    func predictNextWord(
        afterTailWords tailWords: [String],
        configuration: PersonalHistoryConfiguration
    ) -> PersonalNextWordPrediction? {
        guard configuration.revision == configurationRevision, nextWordPhase == .ready else { return nil }
        return nextWord.predictNextWord(afterTailWords: tailWords)
    }

    func nextWordStatus(
        configuration: PersonalHistoryConfiguration
    ) -> PersonalNextWordShadowStatus {
        guard configuration.revision == configurationRevision else {
            return PersonalNextWordShadowStatus(
                phase: configuration.enabled ? .loading : .inactive,
                snapshot: PersonalNextWordShadow().snapshot
            )
        }
        return PersonalNextWordShadowStatus(phase: nextWordPhase, snapshot: nextWord.snapshot)
    }

    func deleteAll(
        nextHistoryIdentifier: String,
        configuration: PersonalHistoryConfiguration
    ) async throws {
        configurationRevision = max(configurationRevision, configuration.revision)
        replayBacklog.removeAll(keepingCapacity: true)
        replayBacklogOverflowed = false
        nextWord.reset()
        nextWordPhase = .inactive
        historyIdentifier = nextHistoryIdentifier
        // The log and the trained table both go; positions restart with the
        // new store, so no stale coverage can survive the deletion.
        lastAppendedSequence = 0
        lastModelSaveUptime = nil
        modelSaveFailing = false
        let store = store
        let deletion = storageOperations.enqueue { try await store.deleteAll() }
        try await deletion.value
    }
}

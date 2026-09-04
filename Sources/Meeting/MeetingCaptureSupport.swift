import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// Result of a stop request. `didTimeOut == true` means we did not receive
/// `Audio.onRecordingComplete` within `meetingStopTimeout`, so the WAV files
/// at the returned URLs may not be fully finalized — the controller should
/// route the audio to the failed queue rather than enqueuing for transcription.
enum CaptureStopFinalizationOwner: Equatable {
    case audioFinalizer
    case recordingJournalRecovery
}

struct CaptureStopResult {
    let micURL: URL?
    let systemURL: URL?
    let didTimeOut: Bool
    let finalizationOwner: CaptureStopFinalizationOwner

    init(
        micURL: URL?,
        systemURL: URL?,
        didTimeOut: Bool,
        finalizationOwner: CaptureStopFinalizationOwner = .audioFinalizer
    ) {
        self.micURL = micURL
        self.systemURL = systemURL
        self.didTimeOut = didTimeOut
        self.finalizationOwner = finalizationOwner
    }
}

/// Closure-free identity retained after a timed-out stop callback expires.
/// The bridge bounds these values separately from callback closures so a late
/// completion can still honor a failed-row delete or an explicit discard.
enum TimedOutStopCompletionOwner: Equatable {
    case failedMeeting(UUID)
    case discard
}

enum ExpiredTimedOutCompletionFallback: Equatable {
    case recoverJournal
    case discardFinalizedAudio

    static func action(hasMatchingJournal: Bool) -> Self {
        hasMatchingJournal ? .recoverJournal : .discardFinalizedAudio
    }
}

/// Orders late stop finalization against failed-row persistence. Audio's
/// recording journal keeps owning unfinished segments until finalization; the
/// failed row and merged-sibling reconciliation own the retryable result.
enum TimedOutFailedMeetingFinalizationAction {
    case buffered
    case promote(CaptureStopResult)
    case discard(CaptureStopResult)
    case journalOwned
}

struct TimedOutFailedMeetingFinalizationHandoff {
    private enum State {
        case awaitingCallback
        case bufferedBeforePersistence(CaptureStopResult)
        case bufferedForPromotion(CaptureStopResult)
        case discardOnCallback
        case journalOwned
    }

    private static let ownershipCapacity = 4
    private var states: [UUID: State] = [:]
    private var order: [UUID] = []

    var bufferedResultCount: Int {
        states.values.reduce(into: 0) { count, state in
            if case .bufferedBeforePersistence = state { count += 1 }
            if case .bufferedForPromotion = state { count += 1 }
        }
    }
    var persistedOwnershipIDs: Set<UUID> {
        Set(states.compactMap { id, state in
            switch state {
            case .awaitingCallback, .bufferedForPromotion:
                return id
            case .bufferedBeforePersistence, .discardOnCallback, .journalOwned:
                return nil
            }
        })
    }
    var terminalOwnershipCount: Int {
        states.values.reduce(into: 0) { count, state in
            if case .discardOnCallback = state { count += 1 }
            if case .journalOwned = state { count += 1 }
        }
    }
    func hasOwnership(of id: UUID) -> Bool { states[id] != nil }

    mutating func receive(
        _ result: CaptureStopResult,
        for id: UUID,
        failedMeetingIsPersisted: Bool
    ) -> TimedOutFailedMeetingFinalizationAction {
        if let state = states[id] {
            switch state {
            case .discardOnCallback:
                remove(id)
                return .discard(result)
            case .journalOwned:
                remove(id)
                return .journalOwned
            case .awaitingCallback where !failedMeetingIsPersisted:
                remove(id)
                return .discard(result)
            case .awaitingCallback, .bufferedBeforePersistence, .bufferedForPromotion:
                break
            }
        }

        if result.finalizationOwner == .recordingJournalRecovery {
            if failedMeetingIsPersisted {
                remove(id)
            } else {
                store(.journalOwned, for: id)
            }
            return .journalOwned
        }

        store(
            failedMeetingIsPersisted
                ? .bufferedForPromotion(result)
                : .bufferedBeforePersistence(result),
            for: id
        )
        return failedMeetingIsPersisted ? .promote(result) : .buffered
    }

    mutating func failedMeetingDidPersist(id: UUID) -> CaptureStopResult? {
        if case .journalOwned = states[id] {
            remove(id)
            return nil
        }
        if case .bufferedBeforePersistence(let result) = states[id] {
            store(.bufferedForPromotion(result), for: id)
            return result
        }
        if case .bufferedForPromotion(let result) = states[id] {
            return result
        }
        if states[id] == nil {
            store(.awaitingCallback, for: id)
        }
        return nil
    }

    func audioForPersistence(
        id: UUID,
        provisionalMicURL: URL?,
        provisionalSystemURL: URL?
    ) -> (micURL: URL?, systemURL: URL?) {
        let finalizedResult: CaptureStopResult?
        switch states[id] {
        case .bufferedBeforePersistence(let result), .bufferedForPromotion(let result):
            finalizedResult = result
        default:
            finalizedResult = nil
        }
        return (
            micURL: preferredPersistenceURL(
                provisional: provisionalMicURL,
                finalized: finalizedResult?.micURL
            ),
            systemURL: preferredPersistenceURL(
                provisional: provisionalSystemURL,
                finalized: finalizedResult?.systemURL
            )
        )
    }

    private func preferredPersistenceURL(provisional: URL?, finalized: URL?) -> URL? {
        var isDirectory: ObjCBool = false
        if let provisional,
           FileManager.default.fileExists(atPath: provisional.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return provisional
        }
        isDirectory = false
        if let finalized,
           FileManager.default.fileExists(atPath: finalized.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return finalized
        }
        // Preserve the original timeout snapshot when neither candidate is on
        // disk yet; the recording journal remains the durable recovery owner.
        return provisional ?? finalized
    }

    mutating func markDeliverySucceeded(id: UUID) {
        remove(id)
    }

    mutating func markPersistenceFailed(id: UUID) {
        // There is no row that can consume this in-memory result. The existing
        // recording journal remains the durable recovery owner across launch.
        switch states[id] {
        case .bufferedBeforePersistence, .bufferedForPromotion:
            remove(id)
        case .awaitingCallback, nil:
            store(.journalOwned, for: id)
        case .journalOwned:
            remove(id)
        case .discardOnCallback:
            break
        }
    }

    mutating func markTerminalDiscard(id: UUID) -> CaptureStopResult? {
        switch states[id] {
        case .bufferedBeforePersistence(let result), .bufferedForPromotion(let result):
            remove(id)
            return result
        case .awaitingCallback:
            store(.discardOnCallback, for: id)
        case .discardOnCallback, .journalOwned, nil:
            break
        }
        return nil
    }

    private mutating func store(_ state: State, for id: UUID) {
        if states.updateValue(state, forKey: id) == nil {
            order.append(id)
        }
        while order.count > Self.ownershipCapacity {
            let evictedID = order.removeFirst()
            // The bridge keeps at most two late callbacks alive, so an older
            // handoff can no longer be delivered. Its journal remains durable.
            states.removeValue(forKey: evictedID)
        }
    }

    private mutating func remove(_ id: UUID) {
        states.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }
}

/// Owns callbacks for stops that timed out but may still finalize. A new
/// recording retains the immediately preceding stop so its late completion can
/// still be delivered, then prunes older stops whose journal/failed row owns
/// recovery. This prevents never-completing stops from accumulating closures.
enum TimedOutStopCompletionResolution {
    case pending(((CaptureStopResult) -> Void)?)
    case expired(TimedOutStopCompletionOwner?)
    case unowned
}

struct TimedOutStopCompletionRegistry {
    private struct PendingCompletion {
        let owner: TimedOutStopCompletionOwner?
        let handler: ((CaptureStopResult) -> Void)?
    }

    private struct Tombstone {
        let generation: UInt64
        let owner: TimedOutStopCompletionOwner
    }

    private static let tombstoneCapacity = 4
    private var pending: [UInt64: PendingCompletion] = [:]
    private var tombstones: [Tombstone] = []
    private var latestExpiredGeneration: UInt64?

    var generations: Set<UInt64> { Set(pending.keys) }
    var handlerCount: Int { pending.values.filter { $0.handler != nil }.count }
    var expiredOwnerCount: Int { tombstones.count }

    mutating func register(
        generation: UInt64,
        owner: TimedOutStopCompletionOwner? = nil,
        handler: ((CaptureStopResult) -> Void)?
    ) {
        pending[generation] = PendingCompletion(owner: owner, handler: handler)
        tombstones.removeAll { $0.generation == generation }
    }

    mutating func resolve(generation: UInt64) -> TimedOutStopCompletionResolution {
        if let completion = pending.removeValue(forKey: generation) {
            return .pending(completion.handler)
        }
        if let index = tombstones.firstIndex(where: { $0.generation == generation }) {
            return .expired(tombstones.remove(at: index).owner)
        }
        if let latestExpiredGeneration, generation <= latestExpiredGeneration {
            return .expired(nil)
        }
        return .unowned
    }

    @discardableResult
    mutating func expire(generation: UInt64) -> Bool {
        guard let completion = pending.removeValue(forKey: generation) else { return false }
        if let owner = completion.owner {
            storeTombstone(owner, for: generation)
        }
        latestExpiredGeneration = max(latestExpiredGeneration ?? 0, generation)
        return true
    }

    @discardableResult
    mutating func prune(olderThan latestCompletedStopGeneration: UInt64) -> Set<UInt64> {
        let staleGenerations = pending.keys.filter { $0 < latestCompletedStopGeneration }
        for generation in staleGenerations {
            if let owner = pending.removeValue(forKey: generation)?.owner {
                storeTombstone(owner, for: generation)
            }
        }
        if let latestPrunedGeneration = staleGenerations.max() {
            latestExpiredGeneration = max(
                latestExpiredGeneration ?? 0,
                latestPrunedGeneration
            )
        }
        return Set(staleGenerations)
    }

    private mutating func storeTombstone(
        _ owner: TimedOutStopCompletionOwner,
        for generation: UInt64
    ) {
        tombstones.removeAll { $0.generation == generation }
        tombstones.append(Tombstone(generation: generation, owner: owner))
        while tombstones.count > Self.tombstoneCapacity {
            tombstones.removeFirst()
        }
    }
}

// @MainActor because every real usage lives inside MeetingCaptureBridge
// (@MainActor), including its deinit. Without this annotation the type was
// safe only by convention: nothing stopped a future caller from touching it
// off-main, and a dropped-without-resume CheckedContinuation is a runtime
// trap hazard. Marking the class @MainActor makes that confinement
// compiler-checked instead of relying on every call site staying disciplined.
//
// The token/payload shape below is a direct re-expression of the previous
// `attemptID: UUID?` + `continuation: CheckedContinuation<Output, Never>?`
// pair using `SupersessionEpoch` + `ClaimSlot` (Sources/TranscriptedCore/
// Utilities/SupersessionEpoch.swift). This is a safe drop-in, not a
// behavior change: `attemptID` was only ever minted by `begin()` and
// compared against `self.attemptID` on the *same* `MeetingCaptureAttempt`
// instance (never logged, persisted, or compared across bridge instances),
// so the UUID's global uniqueness was never actually load-bearing — a
// per-instance monotonic token is observationally identical for every real
// comparison this type performs.
//
// `reset()`/`resetIfCurrent(_:)` return an *array* rather than a single
// optional continuation because a caller can `joinIfActive(_:)` an
// already-in-flight attempt instead of starting its own: two overlapping
// `MeetingCaptureBridge.stopAndAwaitFiles()` calls must resolve to the exact
// same `CaptureStopResult`, not each mint their own `begin()`/token and race
// Core's real completion callback against each other. Every element of the
// returned array must be resumed with the *same* value by the caller, so
// every waiter observes the one true outcome of the one underlying
// operation (`audio.stop()` is only ever called once per attempt).
@MainActor
final class MeetingCaptureAttempt<Output> {
    private var epoch = SupersessionEpoch()
    private var slot = ClaimSlot<CheckedContinuation<Output, Never>>()
    private var waiters: [CheckedContinuation<Output, Never>] = []
    private var isActive = false
    private var timeoutTask: Task<Void, Never>?

    deinit {
        timeoutTask?.cancel()
    }

    func begin(_ continuation: CheckedContinuation<Output, Never>) -> SupersessionEpoch.Token {
        let token = epoch.begin()
        // Matches the previous behavior exactly: silently displaces whatever
        // was stashed before. Callers remain responsible for resolving any
        // outstanding attempt (via `reset()`) — or joining it (via
        // `joinIfActive(_:)`) — before starting a new one.
        slot.install(continuation, ownedBy: token)
        waiters.removeAll()
        isActive = true
        return token
    }

    /// Appends `continuation` as an additional waiter on the attempt already
    /// in flight, returning `true` if there was one to join. Returns `false`
    /// (and leaves `continuation` untouched, for the caller to `begin()` its
    /// own attempt) when nothing is active.
    @discardableResult
    func joinIfActive(_ continuation: CheckedContinuation<Output, Never>) -> Bool {
        guard isActive else { return false }
        waiters.append(continuation)
        return true
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        timeoutTask?.cancel()
        timeoutTask = task
    }

    /// Unconditionally clears the pending attempt — primary continuation and
    /// every joined waiter alike — and returns every continuation that must
    /// now be resumed with the same value, exactly once each.
    func reset() -> [CheckedContinuation<Output, Never>] {
        timeoutTask?.cancel()
        timeoutTask = nil
        isActive = false
        var resolved: [CheckedContinuation<Output, Never>] = []
        if let primary = slot.clear() {
            resolved.append(primary)
        }
        resolved.append(contentsOf: waiters)
        waiters.removeAll()
        return resolved
    }

    func resetIfCurrent(_ token: SupersessionEpoch.Token) -> [CheckedContinuation<Output, Never>] {
        guard epoch.isCurrent(token) else { return [] }
        return reset()
    }
}

enum MeetingCaptureCompletionDisposition: Equatable {
    case expectedStop
    case unexpectedCurrentStop
    case stale
}

enum MeetingCaptureCompletionPolicy {
    static func disposition(
        completionGeneration: UInt64,
        expectedStopGeneration: UInt64?,
        currentAudioGeneration: UInt64
    ) -> MeetingCaptureCompletionDisposition {
        if let expectedStopGeneration,
           expectedStopGeneration == completionGeneration {
            return .expectedStop
        }

        if currentAudioGeneration == completionGeneration {
            return .unexpectedCurrentStop
        }

        return .stale
    }
}

enum MeetingCaptureVolumeDiagnostics {
    private static let changeThreshold = 0.02
    private static let quietMicRawPeakThreshold = 0.05
    private static let usableMicProcessedPeakThreshold = 0.12
    private static let routePrefixes = [
        "default_input",
        "default_output",
        "default_system_output",
    ]

    static func annotatedStopContext(
        baseContext: [String: String],
        afterStopContext: [String: String]
    ) -> [String: String] {
        var context = baseContext.merging(afterStopContext, uniquingKeysWith: { _, new in new })

        for prefix in routePrefixes {
            let change = volumeChange(
                before: context["\(prefix)_volume_before"],
                after: context["\(prefix)_volume_after"] ?? context["\(prefix)_volume_during"]
            )
            context["\(prefix)_volume_changed"] = change.changedState
            context["\(prefix)_volume_dropped"] = change.droppedState
        }

        let capturedInputVolumeBefore = context["captured_input_volume_before"]
        let capturedInputVolumeCurrent = context["captured_input_volume_after"] ?? context["captured_input_volume_during"]
        let capturedInputContextPresent = capturedInputVolumeBefore != nil || capturedInputVolumeCurrent != nil
        let capturedInputChange = volumeChange(
            before: capturedInputVolumeBefore,
            after: capturedInputVolumeCurrent
        )
        context["captured_input_volume_changed"] = capturedInputChange.changedState
        context["captured_input_volume_dropped"] = capturedInputChange.droppedState

        let quietMicState = quietMicRecoveryState(
            rawPeak: context["mic_raw_peak"],
            processedPeak: context["mic_processed_peak"]
        )
        context["quiet_mic_recovered"] = quietMicState.recovered
        context["quiet_mic_unrecovered"] = quietMicState.unrecovered

        // Issue #500: classify WHICH attenuation (if any) hit this recording so
        // reports can tell the two distinct sub-bugs apart instead of lumping
        // every quiet mic together. `input_volume_scalar_available` records
        // whether the hardware even exposes a readable input scalar (often
        // absent on Apple Silicon built-in mics), which is what makes the
        // scalar-drop case detectable in the first place.
        let capturedInputScalarAvailable = inputScalarReadable(
            before: capturedInputVolumeBefore,
            current: capturedInputVolumeCurrent
        )
        let defaultInputScalarAvailable = inputScalarReadable(
            before: context["default_input_volume_before"],
            current: context["default_input_volume_after"] ?? context["default_input_volume_during"]
        )
        let inputScalarAvailable = capturedInputContextPresent ? capturedInputScalarAvailable : defaultInputScalarAvailable
        context["input_volume_scalar_available"] = inputScalarAvailable ? "true" : "false"
        context["attenuation_kind"] = attenuationKind(
            quietMic: quietMicState,
            inputVolumeDropped: selectedInputVolumeDropState(
                captured: capturedInputChange.droppedState,
                capturedContextPresent: capturedInputContextPresent,
                defaultInput: context["default_input_volume_dropped"]
            ),
            agcActive: context["realtime_agc"] == "true"
        )

        context["output_ducking_detected"] = outputDuckingState(
            dropStates: [
                context["default_output_volume_dropped"],
                context["default_system_output_volume_dropped"],
                optionalVolumeDrop(
                    before: context["default_output_volume_before"],
                    after: context["default_output_volume_during"]
                ),
                optionalVolumeDrop(
                    before: context["default_system_output_volume_before"],
                    after: context["default_system_output_volume_during"]
                ),
            ]
        )

        return context
    }

    private static func optionalVolumeDrop(before: String?, after: String?) -> String? {
        guard after != nil else { return nil }
        return volumeChange(before: before, after: after).droppedState
    }

    private static func volumeChange(before: String?, after: String?) -> (changedState: String, droppedState: String) {
        guard let before = scalarValue(before),
              let after = scalarValue(after) else {
            return ("unavailable", "unavailable")
        }

        let delta = after - before
        return (
            abs(delta) >= changeThreshold ? "true" : "false",
            delta <= -changeThreshold ? "true" : "false"
        )
    }

    private static func scalarValue(_ rawValue: String?) -> Double? {
        guard let rawValue,
              rawValue != "unavailable",
              let value = Double(rawValue),
              value.isFinite else {
            return nil
        }
        return value
    }

    private static func quietMicRecoveryState(
        rawPeak: String?,
        processedPeak: String?
    ) -> (recovered: String, unrecovered: String) {
        guard let rawPeak = scalarValue(rawPeak),
              let processedPeak = scalarValue(processedPeak) else {
            return ("unavailable", "unavailable")
        }

        guard rawPeak > 0, rawPeak < quietMicRawPeakThreshold else {
            return ("false", "false")
        }

        if processedPeak >= usableMicProcessedPeakThreshold {
            return ("true", "false")
        }

        return ("false", "true")
    }

    private static func inputScalarReadable(before: String?, current: String?) -> Bool {
        scalarValue(before) != nil || scalarValue(current) != nil
    }

    private static func selectedInputVolumeDropState(
        captured: String,
        capturedContextPresent: Bool,
        defaultInput: String?
    ) -> String? {
        capturedContextPresent ? captured : defaultInput
    }

    /// Classify which issue #500 sub-mechanism (if any) attenuated the mic on
    /// this recording, from facts already derived above:
    ///
    ///   - `scalar_drop`: a meeting app (classically Chrome/WebRTC) drove the
    ///     input device volume scalar down. A clean linear level change, fully
    ///     recoverable by gain.
    ///   - `voice_processed`: the raw mic was quiet but the input volume scalar
    ///     did NOT drop — the signature of a foreign app holding the shared
    ///     input device in macOS voice-processing / communication mode
    ///     (Zoom, native WhatsApp, an empty Google Meet). Nonlinear, lossy, and
    ///     only partially recoverable. This is issue #500's still-open case.
    ///   - `none`: the mic was not quiet; no attenuation observed.
    ///   - `unavailable`: not enough signal to classify: no mic peak data, or
    ///     a quiet mic with no scalar drop while no software AGC ran. Without
    ///     AGC, "quiet raw and quiet processed" is what a listening user looks
    ///     like in Raw or Apple voice-processing mode; only gain that could
    ///     not recover the mic is evidence of voice-processing attenuation.
    ///     This mirrors the live `QuietMicAttenuationDetector`, which never
    ///     fires without gain evidence either.
    private static func attenuationKind(
        quietMic: (recovered: String, unrecovered: String),
        inputVolumeDropped: String?,
        agcActive: Bool
    ) -> String {
        let micStateKnown = quietMic.recovered != "unavailable"
            || quietMic.unrecovered != "unavailable"
        guard micStateKnown else { return "unavailable" }

        let quiet = quietMic.recovered == "true" || quietMic.unrecovered == "true"
        guard quiet else { return "none" }

        if inputVolumeDropped == "true" { return "scalar_drop" }

        // Quiet raw mic with no visible scalar drop (whether the scalar was
        // readable-but-flat or unavailable) is voice-processing attenuation,
        // but only when software gain was there to fail at recovering it.
        return agcActive ? "voice_processed" : "unavailable"
    }

    /// Issue #500 still-open case: quiet raw mic that gain could not recover,
    /// with no input-scalar drop — a foreign app holds the device in voice mode.
    static func isVoiceProcessedUnrecovered(in context: [String: String]) -> Bool {
        context["attenuation_kind"] == "voice_processed"
            && context["quiet_mic_unrecovered"] == "true"
    }

    private static func outputDuckingState(dropStates: [String?]) -> String {
        let values = dropStates.compactMap { $0 }
        if values.contains("true") { return "true" }
        if values.allSatisfy({ $0 == "false" }) { return "false" }
        return "unavailable"
    }
}

enum MeetingAudioInactivityRecoveryPolicy {
    private static let longRecordingThreshold: TimeInterval = 10 * 60
    private static let routeChurnThreshold = 2

    static func warning(
        from warning: MeetingAudioInactivityWarning,
        durationSeconds: TimeInterval,
        diagnostics: [String: String]
    ) -> MeetingAudioInactivityWarning {
        let kind = warningKind(
            durationSeconds: durationSeconds,
            diagnostics: diagnostics
        )
        return MeetingAudioInactivityWarning(
            inactiveDuration: warning.inactiveDuration,
            countdownSeconds: warning.countdownSeconds,
            kind: kind,
            automaticStopAllowed: kind == .noAudio
        )
    }

    static func warningKind(
        durationSeconds: TimeInterval,
        diagnostics: [String: String]
    ) -> MeetingAudioInactivityWarning.Kind {
        guard durationSeconds >= longRecordingThreshold else {
            return .noAudio
        }

        let inputVolumeDropped = selectedInputVolumeDropped(diagnostics)
        let quietMicRecovered = diagnostics["quiet_mic_recovered"] == "true"
        let systemSilent = diagnostics["system_status"] == "silent"
        let routeChurned = intValue(diagnostics["route_change_count"]) >= routeChurnThreshold
        let bluetoothRoute = diagnostics["input_device_class"] == "bluetooth"
            || diagnostics["output_device_class"] == "bluetooth"
            || diagnostics["system_output_device_class"] == "bluetooth"

        if inputVolumeDropped || (systemSilent && (routeChurned || bluetoothRoute || quietMicRecovered)) {
            return .degradedRoute
        }

        return .noAudio
    }

    private static func selectedInputVolumeDropped(_ diagnostics: [String: String]) -> Bool {
        let capturedInputContextPresent = diagnostics["captured_input_volume_before"] != nil
            || diagnostics["captured_input_volume_after"] != nil
            || diagnostics["captured_input_volume_during"] != nil
        let selectedDropState = capturedInputContextPresent
            ? diagnostics["captured_input_volume_dropped"]
            : diagnostics["default_input_volume_dropped"]
        return selectedDropState == "true"
    }

    private static func intValue(_ rawValue: String?) -> Int {
        guard let rawValue else { return 0 }
        return Int(rawValue) ?? 0
    }
}

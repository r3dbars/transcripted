import Foundation

/// Result of a stop request. `didTimeOut == true` means we did not receive
/// `Audio.onRecordingComplete` within `meetingStopTimeout`, so the WAV files
/// at the returned URLs may not be fully finalized — the controller should
/// route the audio to the failed queue rather than enqueuing for transcription.
struct CaptureStopResult {
    let micURL: URL?
    let systemURL: URL?
    let didTimeOut: Bool
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

        store(
            failedMeetingIsPersisted
                ? .bufferedForPromotion(result)
                : .bufferedBeforePersistence(result),
            for: id
        )
        return failedMeetingIsPersisted ? .promote(result) : .buffered
    }

    mutating func failedMeetingDidPersist(id: UUID) -> CaptureStopResult? {
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
        case .discardOnCallback, .journalOwned:
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
struct TimedOutStopCompletionRegistry {
    private(set) var generations: Set<UInt64> = []
    private var handlers: [UInt64: (CaptureStopResult) -> Void] = [:]
    private(set) var latestExpiredGeneration: UInt64?

    var handlerCount: Int { handlers.count }

    mutating func register(
        generation: UInt64,
        handler: ((CaptureStopResult) -> Void)?
    ) {
        generations.insert(generation)
        handlers[generation] = handler
    }

    mutating func takeHandler(for generation: UInt64) -> ((CaptureStopResult) -> Void)? {
        guard generations.remove(generation) != nil else { return nil }
        return handlers.removeValue(forKey: generation)
    }

    @discardableResult
    mutating func expire(generation: UInt64) -> Bool {
        guard generations.remove(generation) != nil else { return false }
        handlers.removeValue(forKey: generation)
        latestExpiredGeneration = max(latestExpiredGeneration ?? 0, generation)
        return true
    }

    func isExpired(_ generation: UInt64) -> Bool {
        guard let latestExpiredGeneration else { return false }
        return !generations.contains(generation)
            && generation <= latestExpiredGeneration
    }

    @discardableResult
    mutating func prune(olderThan latestCompletedStopGeneration: UInt64) -> Set<UInt64> {
        let staleGenerations = generations.filter { $0 < latestCompletedStopGeneration }
        generations.subtract(staleGenerations)
        for generation in staleGenerations {
            handlers.removeValue(forKey: generation)
        }
        return Set(staleGenerations)
    }
}

final class MeetingCaptureAttempt<Output> {
    private var continuation: CheckedContinuation<Output, Never>?
    private var attemptID: UUID?
    private var timeoutTask: Task<Void, Never>?

    deinit {
        timeoutTask?.cancel()
    }

    func begin(_ continuation: CheckedContinuation<Output, Never>) -> UUID {
        let attemptID = UUID()
        self.continuation = continuation
        self.attemptID = attemptID
        return attemptID
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        timeoutTask?.cancel()
        timeoutTask = task
    }

    func reset() -> CheckedContinuation<Output, Never>? {
        let continuation = continuation
        timeoutTask?.cancel()
        timeoutTask = nil
        self.continuation = nil
        attemptID = nil
        return continuation
    }

    func resetIfCurrent(_ attemptID: UUID) -> CheckedContinuation<Output, Never>? {
        guard self.attemptID == attemptID else { return nil }
        return reset()
    }
}

enum MeetingCaptureCompletionDisposition: Equatable {
    case expectedStop
    case lateTimedOutStop
    case unexpectedCurrentStop
    case stale
}

enum MeetingCaptureCompletionPolicy {
    static func disposition(
        completionGeneration: UInt64,
        expectedStopGeneration: UInt64?,
        timedOutStopGenerations: Set<UInt64>,
        currentAudioGeneration: UInt64
    ) -> MeetingCaptureCompletionDisposition {
        if timedOutStopGenerations.contains(completionGeneration) {
            return .lateTimedOutStop
        }

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
            )
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
    ///   - `unavailable`: not enough signal (no mic peak data) to classify.
    private static func attenuationKind(
        quietMic: (recovered: String, unrecovered: String),
        inputVolumeDropped: String?
    ) -> String {
        let micStateKnown = quietMic.recovered != "unavailable"
            || quietMic.unrecovered != "unavailable"
        guard micStateKnown else { return "unavailable" }

        let quiet = quietMic.recovered == "true" || quietMic.unrecovered == "true"
        guard quiet else { return "none" }

        if inputVolumeDropped == "true" { return "scalar_drop" }

        // Quiet raw mic with no visible scalar drop (whether the scalar was
        // readable-but-flat or unavailable) is voice-processing attenuation.
        return "voice_processed"
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

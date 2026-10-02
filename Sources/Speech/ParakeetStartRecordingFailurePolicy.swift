import AVFoundation
import Foundation

/// Distinguishes a blocked audio-engine worker from a worker that actually
/// exceeded its deadline. Circuit-open work remains fail-closed without
/// abandoning the graph that never started.
enum ParakeetAudioEngineWorkError: LocalizedError {
    case timedOut(operation: String, timeoutMs: Int)
    case circuitOpen(operation: String, activeWorkers: Int)

    var isTimedOut: Bool {
        if case .timedOut = self { return true }
        return false
    }

    var requiresGraphAbandonment: Bool {
        isTimedOut
    }

    var isCircuitOpen: Bool {
        if case .circuitOpen = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .timedOut(let operation, let timeoutMs):
            return "Audio engine \(operation) timed out after \(timeoutMs)ms"
        case .circuitOpen(let operation, let activeWorkers):
            return "Audio engine \(operation) skipped while \(activeWorkers) timed operations are still running"
        }
    }
}

enum ParakeetStartRecordingFailureReason: Equatable {
    case invalidAudioFormat
    case audioRouteNotSettled
    case audioEngineStartFailed
    case audioEngineStartTimedOut
}

struct ParakeetStartRecordingFailureAction: Equatable {
    let markFormatUnready: Bool
    let schedulePrewarmRetry: Bool
    let rebuildAudioEngine: Bool
}

struct ParakeetDeviceRecoveryFailureAction: Equatable {
    let reportSentryFailure: Bool
    let markRecordingInterrupted: Bool
    let schedulePrewarmRetry: Bool
}

enum ParakeetDeviceRecoveryReadinessAction: Equatable {
    case finishRecovery
    case keepWaiting
}

enum ParakeetAudioEngineRebuildStrategy: Equatable {
    case queuedOnAudioEngineQueue
    case abandonBlockedAudioGraph
}

enum ParakeetConfigChangeSource: Equatable, Sendable {
    case audioEngine
    case defaultInputDevice
}

enum ParakeetConfigChangeGraphStrategy: Equatable {
    case reuseCurrentGraph
    case rebuildGraph
}

/// Chooses whether a configuration notification requires replacing the whole
/// AVAudioEngine or whether recovery can restart the current graph in place.
///
/// Releasing a retired AVAudioEngine can make CoreAudio stop the replacement
/// engine and post a late configuration notification even though the physical
/// route did not change. Rebuilding again for that notification retires another
/// engine and creates a self-sustaining five-second recovery loop. A proven
/// recording on the exact same process-local graph endpoints can safely reuse
/// its current graph. The system default input and selection reason are not
/// graph endpoints: they may change while Transcripted keeps the same explicit
/// mic and output. Changed, unknown, unready, or sample-unproven active graphs
/// keep the full rebuild path. Idle notifications never reach this policy;
/// they defer validation until the next explicit dictation. Telemetry remains
/// categorical and never receives this identity.
enum ParakeetConfigChangeGraphPolicy {
    static func strategy(
        source: ParakeetConfigChangeSource,
        wasRecording: Bool,
        hadSampleFlow: Bool,
        inputWasReady: Bool,
        stableRouteIdentity: ParakeetAudioRouteIdentity?,
        observedRouteIdentity: ParakeetAudioRouteIdentity?,
        forceForMicrophoneSharing: Bool
    ) -> ParakeetConfigChangeGraphStrategy {
        // A call app downgrade swaps the VPIO graph for a regular one, so it
        // rebuilds even when the route endpoints stayed the same.
        guard !forceForMicrophoneSharing,
              wasRecording,
              hadSampleFlow,
              inputWasReady,
              let stableRouteIdentity,
              let observedRouteIdentity,
              stableRouteIdentity.matchesGraphEndpoints(observedRouteIdentity) else {
            return .rebuildGraph
        }
        return .reuseCurrentGraph
    }
}

/// A call app opened while dictation records through Apple voice processing.
/// Only a live recording on dictation's own graph is downgraded: a dictation
/// borrowing the meeting mic has no graph of its own, and a start, stop, or
/// shutdown already owns the graph.
enum ParakeetMicrophoneSharingPolicy {
    static func mayDowngrade(
        callAppRunning: Bool,
        isRecording: Bool,
        borrowsMeetingMic: Bool,
        audioStartInProgress: Bool,
        audioStopInProgress: Bool,
        isShuttingDown: Bool
    ) -> Bool {
        callAppRunning
            && isRecording
            && !borrowsMeetingMic
            && !audioStartInProgress
            && !audioStopInProgress
            && !isShuttingDown
    }
}

enum ParakeetConfigChangeContinuityPolicy {
    static func shouldProbe(
        wasRecording: Bool,
        hadSampleFlow: Bool,
        inputWasReady: Bool,
        graphEndpointsMatch: Bool,
        forceForMicrophoneSharing: Bool
    ) -> Bool {
        // Healthy local samples do not prove a call app can still read its
        // mic, so a call app downgrade is never parked behind a probe.
        !forceForMicrophoneSharing
            && wasRecording && hadSampleFlow && inputWasReady && graphEndpointsMatch
    }

    static func shouldIgnoreAfterProbe(
        wasRecording: Bool,
        inputWasReady: Bool,
        graphEndpointsMatch: Bool,
        sampleArrivedAfterNotification: Bool
    ) -> Bool {
        wasRecording
            && inputWasReady
            && graphEndpointsMatch
            && sampleArrivedAfterNotification
    }
}

struct ParakeetDeviceRecoveryTimeoutAction: Equatable {
    let failureAction: ParakeetDeviceRecoveryFailureAction
    let rebuildStrategy: ParakeetAudioEngineRebuildStrategy
}

enum ParakeetStartRecordingFailurePolicy {
    static func action(
        for reason: ParakeetStartRecordingFailureReason,
        isRecoveryAttempt: Bool
    ) -> ParakeetStartRecordingFailureAction {
        let shouldScheduleRetry: Bool
        let shouldRebuildAudioEngine: Bool
        switch reason {
        case .invalidAudioFormat, .audioEngineStartFailed, .audioEngineStartTimedOut:
            shouldScheduleRetry = !isRecoveryAttempt
            shouldRebuildAudioEngine = true
        case .audioRouteNotSettled:
            shouldScheduleRetry = true
            shouldRebuildAudioEngine = false
        }

        return ParakeetStartRecordingFailureAction(
            markFormatUnready: true,
            schedulePrewarmRetry: shouldScheduleRetry,
            rebuildAudioEngine: shouldRebuildAudioEngine
        )
    }
}

enum ParakeetDeviceRecoveryFailurePolicy {
    static func action(wasRecording: Bool) -> ParakeetDeviceRecoveryFailureAction {
        ParakeetDeviceRecoveryFailureAction(
            reportSentryFailure: wasRecording,
            markRecordingInterrupted: wasRecording,
            schedulePrewarmRetry: true
        )
    }

    /// Choose how to recover the audio graph after a device-change rewarm fails.
    ///
    /// A rewarm fails when the recovery snapshot throws. The only non-stale throw
    /// it can produce is a timed-out audio-engine operation — which means the
    /// serial `audioEngineQueue` is wedged behind a CoreAudio call that never
    /// returned (the classic AirPods/Bluetooth route-switch hang). Queuing a
    /// `rebuildAudioEngine` on that same blocked queue would never run, so the
    /// recovery task hangs forever and the engine stays dead until the user
    /// force-quits (surfacing as `app.unclean_shutdown_detected`).
    ///
    /// When the queue is blocked, abandon the wedged graph instead: swap in a
    /// fresh `AVAudioEngine` and a fresh queue synchronously, mirroring the
    /// recovery-timeout path (`ParakeetDeviceRecoveryTimeoutPolicy`) and the
    /// start-recording timeout path. Non-blocked failures can still rebuild on
    /// the existing queue.
    static func rebuildStrategy(audioEngineQueueBlocked: Bool) -> ParakeetAudioEngineRebuildStrategy {
        audioEngineQueueBlocked ? .abandonBlockedAudioGraph : .queuedOnAudioEngineQueue
    }

    /// The graph repair a failed rewarm gets, from the error it failed with.
    /// Circuit-open work never entered the current queue, so the graph is kept
    /// and the recovery fails closed. A timeout means the queue is wedged, so
    /// the graph is abandoned instead of queuing a rebuild behind it. Anything
    /// else rebuilds in place.
    static func graphRepair(after error: Error) -> ParakeetDeviceRecoveryGraphRepair {
        let workError = error as? ParakeetAudioEngineWorkError
        if workError?.isCircuitOpen == true {
            return .keepCurrentGraph
        }
        switch rebuildStrategy(audioEngineQueueBlocked: workError?.requiresGraphAbandonment == true) {
        case .queuedOnAudioEngineQueue:
            return .rebuildOnAudioEngineQueue
        case .abandonBlockedAudioGraph:
            return .abandonBlockedAudioGraph
        }
    }
}

enum ParakeetDeviceRecoveryGraphRepair: Equatable {
    case keepCurrentGraph
    case rebuildOnAudioEngineQueue
    case abandonBlockedAudioGraph
}

enum ParakeetDeviceRecoveryReadinessPolicy {
    static func action(for readiness: ParakeetAudioFormatReadiness) -> ParakeetDeviceRecoveryReadinessAction {
        switch readiness {
        case .ready:
            return .finishRecovery
        case .invalid, .routeNotSettled:
            return .keepWaiting
        }
    }
}

enum ParakeetDeviceRecoveryStartRetryPolicy {
    static func shouldRetry(
        after failureReason: ParakeetStartRecordingFailureReason?,
        inputCanStartRecording: Bool
    ) -> Bool {
        guard let failureReason else {
            return !inputCanStartRecording
        }
        switch failureReason {
        case .invalidAudioFormat, .audioRouteNotSettled:
            return true
        case .audioEngineStartFailed, .audioEngineStartTimedOut:
            return false
        }
    }
}

/// Bounded attempt state for restarting an interrupted recording after a real
/// endpoint change. CoreAudio can report a usable snapshot and then renegotiate
/// the split Bluetooth route again while the microphone graph starts. Keeping
/// this as explicit state guarantees one post-settle attempt without restoring
/// the old unbounded recovery loop.
struct ParakeetRecordingRestartBudget: Equatable {
    let maxAttempts: Int
    let retryDelayNanoseconds: UInt64
    let deadlineUptime: TimeInterval
    private(set) var attemptsMade = 0

    init(
        maxAttempts: Int = TranscriptedConstants.recordingRestartAttempts,
        retryDelayNanoseconds: UInt64 = TranscriptedConstants.recordingRestartRetryDelay,
        admissionWindow: TimeInterval = TranscriptedConstants.recordingRestartAdmissionWindow,
        startedAtUptime: TimeInterval
    ) {
        self.maxAttempts = max(0, maxAttempts)
        self.retryDelayNanoseconds = retryDelayNanoseconds
        deadlineUptime = startedAtUptime + max(0, admissionWindow)
    }

    mutating func takeNextAttempt(nowUptime: TimeInterval) -> Int? {
        guard attemptsMade < maxAttempts, nowUptime < deadlineUptime else { return nil }
        attemptsMade += 1
        return attemptsMade
    }

    func delayBeforeNextAttempt(nowUptime: TimeInterval) -> UInt64? {
        guard attemptsMade < maxAttempts else { return nil }
        let retryDelaySeconds = Double(retryDelayNanoseconds) / 1_000_000_000
        guard nowUptime + retryDelaySeconds < deadlineUptime else { return nil }
        return retryDelayNanoseconds
    }
}

enum ParakeetDeviceRecoveryTimeoutPolicy {
    static func action(wasRecording: Bool) -> ParakeetDeviceRecoveryTimeoutAction {
        ParakeetDeviceRecoveryTimeoutAction(
            failureAction: ParakeetDeviceRecoveryFailurePolicy.action(wasRecording: wasRecording),
            rebuildStrategy: .abandonBlockedAudioGraph
        )
    }
}

enum ParakeetAudioEngineRetirementPolicy {
    /// CoreAudio can still deliver queued AVAudioIOUnit property-listener blocks
    /// after Transcripted has stopped and replaced an AVAudioEngine during route churn.
    static let deferredReleaseDelayNanoseconds: UInt64 = 5_000_000_000

    /// A notification storm must not retain an unlimited number of native
    /// audio graphs during that safety window. When full, recovery refuses a
    /// further replacement and reuses a successfully reset graph when safe.
    static let maximumRetainedEngineCount = 4
}

enum ParakeetASRManagerCleanupDecision: Equatable {
    case cleanupNow
    case deferUntilProcessExit
}

enum ParakeetASRManagerCleanupPolicy {
    static func decision(isTranscribing: Bool) -> ParakeetASRManagerCleanupDecision {
        isTranscribing ? .deferUntilProcessExit : .cleanupNow
    }
}

struct ParakeetASRInferenceActivityState: Equatable {
    private(set) var activeCount = 0

    var isActive: Bool {
        activeCount > 0
    }

    func canStartImmediately(reservedHandoffCount: Int) -> Bool {
        !isActive && reservedHandoffCount <= 0
    }

    mutating func begin() {
        activeCount += 1
    }

    mutating func finish() {
        activeCount = max(0, activeCount - 1)
    }
}

enum ParakeetAudioFormatReadiness: String, Equatable {
    case ready
    case invalid
    case routeNotSettled

    var startFailureReason: ParakeetStartRecordingFailureReason? {
        switch self {
        case .ready:
            return nil
        case .invalid:
            return .invalidAudioFormat
        case .routeNotSettled:
            return .audioRouteNotSettled
        }
    }
}

enum ParakeetAudioFormatReadinessPolicy {
    private static let likelyBluetoothSpeechRates: Set<Int> = [8_000, 16_000, 24_000]
    static let audioUnitFormatNotSupportedCode = -10_868
    static let fallbackCaptureSampleRate: Double = 48_000
    private static let minimumUsableSampleRate: Double = 8_000
    private static let maximumUsableSampleRate: Double = 384_000
    private static let maximumBufferCapacitySampleRate: Double = 96_000

    static func readiness(
        outputSampleRate: Double,
        outputChannelCount: UInt32,
        inputSampleRate: Double,
        inputChannelCount: UInt32,
        selectedInputClass: String,
        outputDeviceClass: String,
        selectionOverrodeDefault: Bool,
        selectionReason: DictationInputDeviceSelectionReason? = nil
    ) -> ParakeetAudioFormatReadiness {
        guard isUsableCaptureSampleRate(outputSampleRate), outputChannelCount > 0,
              isUsableCaptureSampleRate(inputSampleRate), inputChannelCount > 0 else {
            return .invalid
        }

        let lowRateOutputBus = likelyBluetoothSpeechRates.contains(Int(outputSampleRate.rounded()))
        let overriddenBluetoothOutputRoute = selectionOverrodeDefault
            && outputDeviceClass == "bluetooth"
        let suppressedRecoveryBluetoothRoute = selectedInputClass == "bluetooth"
            && outputDeviceClass == "bluetooth"
            && selectionReason == .builtInFallbackSuppressedForRecoveryAttempt

        if selectedInputClass != "bluetooth",
           inputSampleRate >= 44_100,
           lowRateOutputBus,
           (outputDeviceClass != "bluetooth" || overriddenBluetoothOutputRoute) {
            return .routeNotSettled
        }

        // A native headset can legitimately capture at 8/16/24 kHz on both
        // buses. The recovery fallback explicitly selects that headset, so a
        // matched speech format must be allowed to start. Only keep waiting
        // when the low-rate bus still disagrees with the hardware snapshot.
        if suppressedRecoveryBluetoothRoute, lowRateOutputBus,
           inputSampleRate != outputSampleRate {
            return .routeNotSettled
        }

        return .ready
    }

    static func startFailureReason(for error: NSError) -> ParakeetStartRecordingFailureReason {
        if error.code == audioUnitFormatNotSupportedCode {
            return .audioRouteNotSettled
        }
        return .audioEngineStartFailed
    }

    static func isUsableCaptureSampleRate(_ sampleRate: Double) -> Bool {
        sampleRate.isFinite
            && sampleRate >= minimumUsableSampleRate
            && sampleRate <= maximumUsableSampleRate
    }

    static func captureSampleRateOrFallback(_ sampleRate: Double) -> Double {
        isUsableCaptureSampleRate(sampleRate) ? sampleRate : fallbackCaptureSampleRate
    }

    static func bufferCapacitySampleCount(sampleRate: Double, seconds: Int) -> Int {
        let safeRate = captureSampleRateOrFallback(sampleRate)
        let sampleCount = safeRate * Double(seconds)
        guard sampleCount.isFinite, sampleCount > 0 else {
            return Int(fallbackCaptureSampleRate) * max(seconds, 1)
        }
        return min(Int(sampleCount), Int(maximumBufferCapacitySampleRate) * max(seconds, 1))
    }
}

enum ParakeetInputTapFormatPolicy {
    /// Resolve from the live node *after* applying voice processing. A raw
    /// input node cannot convert hardware audio to a stale output-bus rate.
    /// VPIO owns a processed output format, which must remain authoritative.
    static func format(
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        voiceProcessingEnabled: Bool
    ) throws -> AVAudioFormat {
        let format = voiceProcessingEnabled ? outputFormat : inputFormat
        guard ParakeetAudioFormatReadinessPolicy.isUsableCaptureSampleRate(inputFormat.sampleRate),
              inputFormat.channelCount > 0,
              ParakeetAudioFormatReadinessPolicy.isUsableCaptureSampleRate(format.sampleRate),
              format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32 else {
            // A route can change after the earlier readiness snapshot. Reject
            // an invalid or unsupported format before installTap's native precondition, and
            // reuse the existing bounded route-settling recovery.
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: ParakeetAudioFormatReadinessPolicy.audioUnitFormatNotSupportedCode
            )
        }
        return format
    }
}

enum ParakeetTapSampleRatePolicy {
    static func effectiveSampleRate(
        bufferSampleRate: Double,
        hardwareSampleRate _: Double? = nil
    ) -> Double {
        ParakeetAudioFormatReadinessPolicy.captureSampleRateOrFallback(bufferSampleRate)
    }
}

enum ParakeetSampleSignalPolicy {
    private static let nonZeroSignalThreshold: Float = 0.000_001

    static func hasNonZeroSignal(_ samples: [Float]) -> Bool {
        samples.contains { abs($0) > nonZeroSignalThreshold }
    }

    static func shouldResetStartupAudio(
        sampleCount: Int,
        hasNonZeroSignal: Bool,
        isLikelyBluetoothHandsFreeRoute: Bool
    ) -> Bool {
        sampleCount == 0 || (sampleCount > 0 && !hasNonZeroSignal && isLikelyBluetoothHandsFreeRoute)
    }
}

enum ParakeetRouteDiagnosticsPolicy {
    static func routeShape(
        selectedInputClass: String,
        outputDeviceClass: String
    ) -> String {
        "\(selectedInputClass)_input_to_\(outputDeviceClass)_output"
    }

    static func isLikelyBluetoothHandsFreeProfile(
        inputClass: String,
        outputDeviceClass: String,
        inputRate: Double?,
        outputRate: Double?
    ) -> Bool {
        guard inputClass == "bluetooth" || outputDeviceClass == "bluetooth" else {
            return false
        }
        // nil rates mean the caller never sampled formats; absence of
        // measurement is not evidence of a degraded route.
        guard let inputRate, let outputRate else { return false }
        // A fully-switched hands-free route degrades BOTH legs to speech rates,
        // and an unsettled route can read 0 on either leg mid-transition; each
        // previously escaped both single-leg branches below as a false negative.
        if inputRate <= 24_000, outputRate <= 24_000 {
            return true
        }
        if inputClass == "bluetooth" {
            return inputRate <= 24_000 && outputRate >= 44_100
        }
        if outputDeviceClass == "bluetooth" {
            return outputRate <= 24_000 && inputRate >= 44_100
        }
        return false
    }
}

struct ParakeetAudioFormatSummary: Equatable {
    let sampleRate: Double
    let channelCount: UInt32
}

// MARK: - Dictation input node steps

/// The live input-node operations the dictation start path runs before it
/// installs its tap. The engine adapts `AVAudioInputNode`; tests use a fake.
/// Nothing here can write the Mac-wide default input: dictation only binds the
/// app's own AUHAL input.
protocol ParakeetDictationTapInputNode {
    func removeInputTap()
    /// Applies the dictation voice-processing preference and reports whether
    /// the node now matches it.
    func applyVoiceProcessingPreference(_ enabled: Bool) -> Bool
    var liveInputFormat: AVAudioFormat { get }
    var liveOutputFormat: AVAudioFormat { get }
    var isVoiceProcessingActive: Bool { get }
}

enum ParakeetDictationTapPreparation {
    /// Clears any old tap, applies voice processing, then resolves the tap
    /// format from the live node. Voice processing can swap the graph's
    /// formats, so the format is read only after it is applied, and the
    /// choice follows the node's actual VPIO state rather than the request.
    static func prepare<Node: ParakeetDictationTapInputNode>(
        _ node: Node,
        voiceProcessingEnabled: Bool,
        isCurrent: () -> Bool,
        stageTimings: inout [String: Int]
    ) throws -> AVAudioFormat {
        let tapRemoveStartedAt = CFAbsoluteTimeGetCurrent()
        node.removeInputTap()
        stageTimings["audio_tap_remove_ms"] = elapsedMilliseconds(since: tapRemoveStartedAt)
        let voiceProcessingStartedAt = CFAbsoluteTimeGetCurrent()
        let appliedVoiceProcessing = node.applyVoiceProcessingPreference(voiceProcessingEnabled)
        guard voiceProcessingEnabled || appliedVoiceProcessing else {
            throw NSError(domain: "ParakeetEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not release Apple voice processing for shared microphone capture."
            ])
        }
        stageTimings["audio_voice_processing_apply_ms"] = elapsedMilliseconds(since: voiceProcessingStartedAt)
        guard isCurrent() else { throw CancellationError() }
        let tapFormat = try ParakeetInputTapFormatPolicy.format(
            inputFormat: node.liveInputFormat,
            outputFormat: node.liveOutputFormat,
            voiceProcessingEnabled: node.isVoiceProcessingActive
        )
        guard isCurrent() else { throw CancellationError() }
        return tapFormat
    }

    private static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Int {
        max(0, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
    }
}

/// The reads `audioInputSnapshot` takes on the audio-engine queue.
protocol ParakeetDictationInputSnapshotGraph {
    associatedtype Application
    var isGraphRunning: Bool { get }
    /// Unwraps a voice-processing aggregate so the next bind sees the physical mic.
    func releaseVoiceProcessing()
    /// Binds the app's own AUHAL input to the chosen microphone.
    func applySelectedInputDevice() -> Application
    var outputFormatSummary: ParakeetAudioFormatSummary { get }
    var inputFormatSummary: ParakeetAudioFormatSummary { get }
}

struct ParakeetDictationInputSnapshotReading<Application> {
    let outputFormat: ParakeetAudioFormatSummary
    let hwFormat: ParakeetAudioFormatSummary
    let selectionApplication: Application
    let engineWasRunning: Bool
}

enum ParakeetDictationInputSnapshotRead {
    /// Moves the input off the default device before reading any format. On an
    /// AirPods default, a format read before the override can pull the headset
    /// into call mode and sample the wrong route.
    static func read<Graph: ParakeetDictationInputSnapshotGraph>(
        _ graph: Graph
    ) -> ParakeetDictationInputSnapshotReading<Graph.Application> {
        if !graph.isGraphRunning {
            graph.releaseVoiceProcessing()
        }
        let selectionApplication = graph.applySelectedInputDevice()
        return ParakeetDictationInputSnapshotReading(
            outputFormat: graph.outputFormatSummary,
            hwFormat: graph.inputFormatSummary,
            selectionApplication: selectionApplication,
            engineWasRunning: graph.isGraphRunning
        )
    }
}

// MARK: - Config-change handling

/// Who owns the audio graph when a route notification lands. Recording
/// startup, a suspended stop, a borrowed meeting mic, and the pinned recorder
/// each own route validation; config-change recovery must stay out of the way.
enum ParakeetConfigChangeAdmissionPolicy {
    static func admits(
        sharedMeetingMicClaimCurrent: Bool,
        audioStartInProgress: Bool,
        audioStopInProgress: Bool,
        pinnedRecordingActive: Bool
    ) -> Bool {
        !sharedMeetingMicClaimCurrent
            && !audioStartInProgress
            && !audioStopInProgress
            && !pinnedRecordingActive
    }
}

enum ParakeetConfigChangeGraphAction: Equatable {
    case reuseCurrentGraph
    case rebuildGraph(requiresFreshGraph: Bool)
}

extension ParakeetConfigChangeGraphPolicy {
    /// A stable same-route echo keeps the current graph so recovery does not
    /// retire another engine (and schedule another late echo). If voice
    /// processing failed to disarm, or a call app needs the mic shared, the
    /// graph is replaced with a fresh one.
    static func action(
        strategy: ParakeetConfigChangeGraphStrategy,
        releasedVoiceProcessing: Bool,
        forceForMicrophoneSharing: Bool
    ) -> ParakeetConfigChangeGraphAction {
        switch releasedVoiceProcessing ? strategy : .rebuildGraph {
        case .reuseCurrentGraph:
            return .reuseCurrentGraph
        case .rebuildGraph:
            return .rebuildGraph(
                requiresFreshGraph: forceForMicrophoneSharing || !releasedVoiceProcessing
            )
        }
    }
}

enum ParakeetConfigChangeDebounce {
    /// Runs once a config-change burst has been quiet for the debounce delay.
    /// Route telemetry is only scheduled, never awaited, so a slow or
    /// unchanged route lookup can't hold back recovery. A newer change
    /// cancels this one before either step runs.
    @MainActor
    static func settle(
        sleep: () async -> Void,
        isCancelled: () -> Bool,
        scheduleStableRouteReport: () -> Void,
        attemptRecovery: () -> Void
    ) async {
        await sleep()
        guard !isCancelled() else { return }
        scheduleStableRouteReport()
        attemptRecovery()
    }
}

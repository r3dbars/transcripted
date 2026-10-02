// ParakeetEngine.swift
// FluidAudio-based STT engine — CoreML Parakeet TDT V2/V3 for batch transcription.
// AVAudioEngine tap → NSLock-batched samples → resampled to 16kHz → AsrManager.transcribe()
// for final batch inference.

import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreAudio
import FluidAudio
import Foundation
import TranscriptedCore

@MainActor
class ParakeetEngine: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var audioLevel: Float = 0
    @Published var modelDownloadState: ParakeetModelState = .notLoaded
    @Published var recordingInterrupted = false
    @Published var isRecovering = false
    @Published var inputFormatReady = true
    var lastEmptyTranscriptionReason: DictationEmptyTranscriptionReason?

    var hasRecoverableRecording: Bool {
        !recoveredRecordingTimeline.isEmpty
    }

    /// The AVAudioEngine graph slot. Every replacement and teardown of the
    /// engine and its queue goes through it (ParakeetAudioGraph.swift).
    let audioGraph = ParakeetAudioGraph(
        driver: ParakeetAVAudioEngineGraphDriver(),
        workLimiter: ParakeetEngine.timedAudioEngineWorkLimiter
    )
    var audioEngine: AVAudioEngine { audioGraph.engine }
    var audioEngineQueue: DispatchQueue { audioGraph.queue }
    static let systemInputWorkCoordinator = ParakeetReplaceableSystemInputWorkCoordinator(
        label: "com.transcripted.parakeet.system-input"
    )
    static let timedAudioEngineWorkLimiter = ParakeetTimedAudioEngineWorkLimiter()
    var audioGraphGeneration: Int {
        get { audioGraph.generation }
        set { audioGraph.generation = newValue }
    }
    var audioStartAdmission: ParakeetAudioStartAdmissionState {
        get { audioGraph.startAdmission }
        set { audioGraph.startAdmission = newValue }
    }
    var audioStartInProgress: Bool { audioStartAdmission.isInProgress }
    let audioStopLifecycle = ParakeetSingleFlightLifecycle()
    var audioStopInProgress: Bool { audioStopLifecycle.isInProgress }
    var inputTapInstalled: Bool {
        get { audioGraph.inputTapInstalled }
        set { audioGraph.inputTapInstalled = newValue }
    }
    /// Set while dictation records through the pinned-device recorder
    /// (ParakeetPinnedMicrophone.swift) instead of this engine.
    var pinnedDictationRecording: ParakeetPinnedDictationRecording?
    /// Set when a pinned start fell back to this engine, cleared when the
    /// recorder next starts. Keeps engine warmup on in between
    /// (`PinnedDictationInputPolicy.skipsEngineWarmup`).
    var pinnedDictationFellBackToEngine = false
    /// The last stopped take the pinned recorder made only for speed, until
    /// its transcript scores it (`PinnedDictationSpeedPath`).
    var pendingPinnedSpeedPathTake: PinnedDictationSpeedPathTake?
    /// The meeting-minted claim on its live mic stream, or `nil` when
    /// dictation owns its own mic path. Replaces the former bare
    /// `sharedMeetingMicRecording: Bool` — see SharedMeetingMicClaim.swift's
    /// header for why a same-process flag with no expiry was unsafe.
    /// Presence-only reads (is dictation in borrowed-mic bookkeeping mode at
    /// all?) test this directly with `!= nil`; the two device-recovery
    /// guards that must treat a claim from a dead meeting session as absent
    /// go through `resolveSharedMeetingMicClaimStatus()` /
    /// `isSharedMeetingMicClaimCurrent` instead.
    var sharedMeetingMicClaim: SharedMeetingMicClaim?
    nonisolated let sharedMeetingMicRecorder = SharedMeetingMicRecorder()
    nonisolated let sharedMeetingMicLevelMeter = SharedMeetingMicLevelMeter()
    var sharedMeetingMicTransition = SharedMeetingMicTransitionState()
    // Completed tap batches and recovery segments share one rate-aware timeline.
    var recordingIdentity = UUID()
    private(set) var recordedSamplesRevision: UInt64 = 0
    var recordedTranscriptionOwnership = ParakeetRecordedTranscriptionOwnership()
    var recoveredRecordingTimeline = RecordedAudioTimeline() {
        didSet { recordedSamplesRevision &+= 1 }
    }
    var preservingRecordingAcrossRecovery = false
    nonisolated(unsafe) var nativeSampleRate: Double = 48000
    nonisolated(unsafe) var audioStartReferenceTime: CFAbsoluteTime?
    let pendingSamplesLock = NSLock()
    var pendingSamples = RecordedAudioTimeline()
    /// The island's live preview copy of this take's audio, guarded by
    /// `pendingSamplesLock`. Nil unless a preview is listening.
    nonisolated(unsafe) var previewSink: DictationPreviewSampleSink?
    var lastAudioSampleAt: CFAbsoluteTime = 0
    /// When the first audio buffer of this dictation arrived. Guarded by
    /// `pendingSamplesLock`; a recovery restart keeps the original value.
    var firstAudioSampleAt: CFAbsoluteTime?
    var didReportPendingSampleTruncation = false
    nonisolated(unsafe) var lastLevelUpdate: CFAbsoluteTime = 0
    var isEnginePrewarmed: Bool {
        get { audioGraph.isPrewarmed }
        set { audioGraph.isPrewarmed = newValue }
    }
    private var wakeObserver: NSObjectProtocol?
    private var microphoneSharingObserver: AnyCancellable?
    var inputDeviceChangeObserverToken: DefaultInputDeviceMonitor.ObserverToken?
    nonisolated let inputDeviceRefreshMailbox = ParakeetInputDeviceRefreshMailbox()
    nonisolated let auhalBindingIntent = ParakeetAUHALBindingIntent()
    static let inputDeviceRefreshWorkCoordinator = ParakeetReplaceableSystemInputWorkCoordinator(
        label: "com.transcripted.parakeet.route-notification"
    )
    private var recentAudioEngineRebuildTimestamps: [CFAbsoluteTime] = []
    private var didReportAudioEngineRebuildChurn = false

    var configChangeObserver: NSObjectProtocol?
    var configChangeDebounceTask: Task<Void, Never>?
    var configRecoveryTask: Task<Void, Never>?
    var configRecoveryTimeoutTask: Task<Void, Never>?
    var routeTransitionDebounceState = ParakeetRouteTransitionDebounceState()
    var stableAudioRouteIdentity: ParakeetAudioRouteIdentity?
    var audioConfigObservationGeneration: UInt64 = 0
    /// Tracks whether a recording was active when the first config change in a
    /// burst arrived. Subsequent changes during recovery inherit this flag so
    /// the final recovery attempt knows to restart recording.
    var configChangeWasRecording = false
    /// Pure-logic state machine for device-change recovery. Owns the generation
    /// counter and the readiness flags. Mirrored into @Published so the UI can
    /// observe via Combine.
    var recoveryState = ParakeetRecoveryState()
    /// Counts consecutive failed prewarm attempts. Reset on successful prewarm or
    /// on a fresh config-change burst. Bounded by `prewarmRetryBudget` to prevent
    /// infinite Task chains when the mic is permanently unavailable.
    var prewarmRetryCount: Int = 0
    var prewarmRetryTask: Task<Void, Never>?
    var isShuttingDown = false

    // FluidAudio ASR
    var asrManager: AsrManager?
    var modelVariant: ParakeetModelVariant = .v3
    var loadedModelVariant: ParakeetModelVariant?
    var modelCleanupTask: Task<Void, Never>?
    let modelTeardownGate = ParakeetModelTeardownGate()
    var modelInitializationTask: Task<Void, Never>?
    var modelInitializationGeneration: UInt64 = 0
    var modelFilePrefetchTask: Task<URL, Error>?
    var prefetchedModelPath: URL?
    var modelDownloadWatchdogTask: Task<Void, Never>?
    var modelDownloadAttemptGeneration: UInt64 = 0
    var audioWatchdogTask: Task<Void, Never>?
    var zombieRecoveryTask: Task<Void, Never>?
    var zombieRecoveryState = ParakeetZombieRecoveryState()
    var audioEngineWorkOwnership: ParakeetTimedAudioEngineWorkOwnership { audioGraph.workOwnership }
    var audioStartCancellationState: ParakeetAudioStartCancellationState?
    var zombieRecoveryStartGeneration: UInt64?
    let asrInferenceGate = ParakeetASRInferenceGate()
    var pureSampleTranscriptionActivityCount = 0
    var asrManagerReady = false
    nonisolated(unsafe) var didReceiveAudioSamples = false
    nonisolated(unsafe) var didReceiveNonZeroAudioSamples = false
    var recordingStartedOnLikelyBluetoothHandsFreeRoute = false
    var cachedInputDeviceName = "Unknown"
    /// Last known dictation input selection, refreshed on start, prewarm,
    /// route/device-change notifications, and background refreshes. Serves
    /// analytics callers without a live CoreAudio device enumeration.
    var cachedInputDeviceSelection: DictationInputDeviceSelection?
    var lastAudioStartFailureReportAt: TimeInterval?
    var lastRecordingStartFailureReason: ParakeetStartRecordingFailureReason?
    var lastInputSelectionReportKey: String?
    var ignoreInputSelectionConfigChangesUntil: CFAbsoluteTime = 0
    var prewarmAdmission = ParakeetPrewarmAdmissionState()

    var isModelLoaded: Bool { asrManagerReady }

    func isModelLoaded(for variant: ParakeetModelVariant) -> Bool {
        asrManagerReady && loadedModelVariant == variant
    }

    func modelDownloadState(for variant: ParakeetModelVariant) -> ParakeetModelState {
        guard variant == modelVariant else {
            return ModelCacheInventory.activeParakeetModelDirectory(variant: variant) != nil
                || bundledParakeetModelPath(variant: variant) != nil ? .cached : .notLoaded
        }
        return modelDownloadState
    }
    var inputDeviceName: String { cachedInputDeviceName }
    var isRecordingFromSharedMeetingMic: Bool { sharedMeetingMicClaim != nil }
    var hasReceivedAudioSamples: Bool { didReceiveAudioSamples }
    /// The last take's mic delivered audio, but every sample was exactly
    /// zero: what a hardware-muted mic sends. Reset at each recording start.
    var lastRecordingWasDigitalSilence: Bool { didReceiveAudioSamples && !didReceiveNonZeroAudioSamples }
    /// Arrival time of this dictation's first audio buffer, for the
    /// press-to-first-sound timing. Nil until audio arrives.
    func firstAudioSampleTime() -> CFAbsoluteTime? {
        pendingSamplesLock.withLock { firstAudioSampleAt }
    }

    func receivedAudioSamples(since observationTime: CFAbsoluteTime) -> Bool {
        pendingSamplesLock.withLock {
            lastAudioSampleAt >= observationTime
        }
    }

    var currentAudioRouteAnalyticsContext: [String: String] {
        // Served from the cached selection: a live lookup enumerates every
        // CoreAudio device (blocking coreaudiod IPC) on the main actor, and
        // analytics tolerates slightly stale route data.
        dictationRouteAnalyticsContext(selection: cachedInputDeviceSelection)
    }

    /// True when the Parakeet model files are already local (bundled,
    /// prefetched, or cached), so initialization is an in-memory load rather
    /// than a network download. Dictation uses this to open the microphone
    /// immediately and load the model concurrently.
    var modelFilesAvailableLocally: Bool {
        modelFilesAvailableLocally(for: modelVariant)
    }

    func modelFilesAvailableLocally(for variant: ParakeetModelVariant) -> Bool {
        if isModelLoaded(for: variant) { return true }
        switch modelDownloadState(for: variant) {
        case .downloading, .failed:
            return false
        case .notLoaded, .cached, .loading, .ready:
            return (variant == modelVariant && prefetchedModelPath != nil && !variant.isLocalInstallOnly)
                || ModelCacheInventory.activeParakeetModelDirectory(variant: variant) != nil
                || bundledParakeetModelPath(variant: variant) != nil
        }
    }

    init() {
        audioGraph.host = self
        markCachedRuntimeModelIfAvailable()
        scheduleInputDeviceNameRefresh()
    }

    nonisolated static func loadDictationInputDeviceSelection(
        allowsBuiltInBluetoothFallback: Bool = true
    ) -> DictationInputDeviceSelection? {
        do {
            return try CoreAudioInputDeviceLookup.preferredDictationInputSelection(
                allowsBuiltInBluetoothFallback: allowsBuiltInBluetoothFallback
            )
        } catch {
            return nil
        }
    }

    nonisolated static var unknownInputDeviceSelection: DictationInputDeviceSelection {
        let unknownDevice = DictationAudioDevice(
            id: AudioDeviceID(kAudioObjectUnknown),
            name: "Unknown",
            transport: .other,
            inputChannelCount: 0
        )
        return DictationInputDeviceSelection(
            defaultInput: unknownDevice,
            selectedInput: unknownDevice,
            defaultOutput: nil,
            reason: .defaultIsSafe
        )
    }

    func runTimedAudioEngineWork<T>(
        operation: String,
        timeoutNanoseconds: UInt64 = TranscriptedConstants.audioStartOperationTimeout,
        isWorkCurrent: (() -> Bool)? = nil,
        cleanupAfterCancellation: ((AVAudioEngine) -> Void)? = nil,
        cleanupAfterLateCompletion: ((AVAudioEngine) -> Void)? = nil,
        _ work: @escaping (AVAudioEngine) throws -> T
    ) async throws -> T {
        try await audioGraph.runTimed(
            operation: operation,
            timeoutNanoseconds: timeoutNanoseconds,
            isWorkCurrent: isWorkCurrent,
            cleanupAfterCancellation: cleanupAfterCancellation,
            cleanupAfterLateCompletion: cleanupAfterLateCompletion,
            work
        )
    }

    func runAudioEngineWork<T>(_ work: @escaping (AVAudioEngine) -> T) async -> T {
        await audioGraph.run(work)
    }

    func installAudioObserversIfNeeded() {
        installAudioEngineConfigObserverIfNeeded()

        if microphoneSharingObserver == nil {
            microphoneSharingObserver = ParakeetCallAppLaunchObservation.observe(
                CallAppMicrophoneSharingMonitor.shared.$isCallAppRunning
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.shareMicrophoneWithCallAppIfNeeded()
                }
            }
        }

        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleSystemWake()
                }
            }
        }

        installInputDeviceChangeListenerIfNeeded()
    }

    func removeRecordingTap(force: Bool = false) async {
        await audioGraph.removeRecordingTap(force: force)
    }

    @discardableResult
    func stopAudioEngine() async -> Bool {
        await audioGraph.stopEngine()
    }

    /// A graph that failed to release VPIO is unsafe to keep for another
    /// capture; ParakeetAudioGraph drops it under its exact owner.
    @discardableResult
    func discardStoppedVoiceProcessingGraph(
        ownedBy owner: ParakeetAudioEngineQueueOwnerToken
    ) -> ParakeetAudioEngineQueueOwnerToken? {
        audioGraph.discardStoppedVoiceProcessingGraph(ownedBy: owner)
    }

    /// Tracks rebuild frequency and reports once if rebuilds are churning —
    /// a guardrail against a route-settling loop silently re-knocking Bluetooth
    /// audio instead of surfacing as a diagnosable failure.
    func trackAudioEngineRebuildChurn(reason: String) {
        let now = CFAbsoluteTimeGetCurrent()
        recentAudioEngineRebuildTimestamps.append(now)
        let windowStart = now - TranscriptedConstants.audioEngineRebuildChurnWindow
        recentAudioEngineRebuildTimestamps.removeAll { $0 < windowStart }
        if recentAudioEngineRebuildTimestamps.count > TranscriptedConstants.audioEngineRebuildChurnThreshold {
            recentAudioEngineRebuildTimestamps.removeFirst(
                recentAudioEngineRebuildTimestamps.count - TranscriptedConstants.audioEngineRebuildChurnThreshold
            )
        }

        guard recentAudioEngineRebuildTimestamps.count >= TranscriptedConstants.audioEngineRebuildChurnThreshold else {
            didReportAudioEngineRebuildChurn = false
            return
        }
        guard !didReportAudioEngineRebuildChurn else { return }
        didReportAudioEngineRebuildChurn = true
        EventReporter.shared.capture(
            level: .error,
            engine: "parakeet",
            event: "audio_engine_rebuild_churn_detected",
            message: "Audio engine rebuilt repeatedly in a short window — likely a route-settling loop",
            context: [
                "reason": reason,
                "rebuild_count": "\(recentAudioEngineRebuildTimestamps.count)",
                "window_seconds": "\(TranscriptedConstants.audioEngineRebuildChurnWindow)"
            ]
        )
    }

    @discardableResult
    func rebuildAudioEngine(
        reason: String,
        requiresFreshGraph: Bool = false
    ) async -> ParakeetAudioGraphOwnerToken? {
        await audioGraph.rebuild(reason: reason, requiresFreshGraph: requiresFreshGraph)
    }

    @discardableResult
    func abandonBlockedAudioEngine(
        reason: String,
        expectedOwner: ParakeetAudioEngineQueueOwnerToken? = nil
    ) -> Bool {
        audioGraph.abandonBlocked(reason: reason, expectedOwner: expectedOwner)
    }

    func currentAudioGraphOwnerToken() -> ParakeetAudioGraphOwnerToken {
        audioGraph.graphOwner
    }

    func ownsAudioGraph(_ owner: ParakeetAudioGraphOwnerToken) -> Bool {
        audioGraph.owns(owner)
    }

    func currentAudioEngineQueueOwnerToken() -> ParakeetAudioEngineQueueOwnerToken {
        audioGraph.queueOwner
    }

    func ownsAudioEngineQueue(_ owner: ParakeetAudioEngineQueueOwnerToken) -> Bool {
        audioGraph.owns(owner)
    }

    func cleanup() {
        sharedMeetingMicTransition.invalidate()
        sharedMeetingMicRecorder.cancel()
        sharedMeetingMicLevelMeter.end()
        sharedMeetingMicClaim = nil
        isShuttingDown = true
        discardPinnedDictationRecording()
        microphoneSharingObserver?.cancel()
        microphoneSharingObserver = nil
        inputDeviceRefreshMailbox.close()
        cancelModelWork()
        cancelAudioWatchdog()
        audioStartAdmission.cancel()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        cancelConfigRecoveryTimeout()
        audioGraphGeneration += 1
        let cleanupGeneration = audioGraphGeneration
        Task { @MainActor [weak self] in
            await self?.releaseIdleAudioHardware(removeTap: true, expectedGeneration: cleanupGeneration)
        }
        isRecording = false
        audioLevel = 0
        removeAudioEngineConfigObserver()
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        removeInputDeviceChangeListener()
        teardownModel()
    }

    deinit {
        inputDeviceRefreshMailbox.close()
        modelInitializationTask?.cancel()
        modelFilePrefetchTask?.cancel()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        // deinit is nonisolated even for an @MainActor class, so unregistering
        // from the @MainActor DefaultInputDeviceMonitor has to hop rather than
        // call synchronously. This is fire-and-forget: the observer closure
        // captures `self` weakly, so any notification that lands before this
        // hop completes is already a safe no-op.
        if let inputDeviceChangeObserverToken {
            Task { @MainActor in
                DefaultInputDeviceMonitor.shared.removeObserver(inputDeviceChangeObserverToken)
            }
        }
        // audioGraph's own deinit cleans up and retires the last engine.
        let mgr = asrManager
        Task { await mgr?.cleanup() }
    }
}

/// The real AVAudioEngine calls behind `ParakeetAudioGraph`. Teardown and the
/// voice-processing probe only look at an input node the engine already has;
/// none of these calls creates one, so none binds the macOS default input.
struct ParakeetAVAudioEngineGraphDriver: ParakeetAudioGraphDriver {
    func makeEngine() -> AVAudioEngine {
        AVAudioEngine()
    }

    func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "com.transcripted.parakeet.audio-engine", qos: .userInitiated)
    }

    func removeInputTap(on engine: AVAudioEngine) -> Bool {
        ParakeetNativeInputGraphTeardown.removeInputTap(LiveParakeetInputGraph(engine: engine))
    }

    func stop(_ engine: AVAudioEngine) -> Bool {
        ParakeetNativeInputGraphTeardown.stop(LiveParakeetInputGraph(engine: engine))
    }

    func reset(_ engine: AVAudioEngine) {
        engine.reset()
    }

    func usesVoiceProcessing(_ engine: AVAudioEngine) -> Bool {
        ParakeetNativeInputGraphTeardown.usesVoiceProcessing(LiveParakeetInputGraph(engine: engine))
    }

    func retire(_ engine: AVAudioEngine, reason: String) -> Bool {
        ParakeetRetiredAudioEngineStore.shared.retire(engine, reason: reason)
    }
}

extension ParakeetEngine: ParakeetAudioStartLeaseHolder {}

extension ParakeetEngine: ParakeetAudioGraphHost {
    func clearGraphSampleFlags() {
        didReceiveAudioSamples = false
        didReceiveNonZeroAudioSamples = false
        recordingStartedOnLikelyBluetoothHandsFreeRoute = false
    }

    func reportAudioGraphEvent(_ event: ParakeetAudioGraphEvent) {
        switch event {
        case .rebuilt(let reason):
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_engine_rebuilt",
                message: "Audio engine rebuilt after microphone graph failure",
                context: [
                    "reason": reason,
                    "recovering": "\(recoveryState.isRecovering)",
                    "format_ready": "\(recoveryState.inputFormatReady)",
                    "generation": "\(recoveryState.generation)"
                ]
            )
        case .abandoned(let reason):
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_engine_rebuilt",
                message: "Audio engine rebuilt after blocked microphone graph recovery",
                context: [
                    "reason": reason,
                    "hard_reset": "true",
                    "recovering": "\(recoveryState.isRecovering)",
                    "format_ready": "\(recoveryState.inputFormatReady)",
                    "generation": "\(recoveryState.generation)"
                ]
            )
        case .zombieReplaced:
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_engine_rebuilt",
                message: "Audio engine replaced after zombie-state detection",
                context: ["reason": "zombie_engine_recovery"]
            )
        case .resetInPlaceAtRetirementLimit:
            AppLogger.transcription.warning(
                "PARAKEET | audio graph reset in place because retirement limit is full"
            )
        case .zombieReplacementRefused:
            AppLogger.transcription.error(
                "PARAKEET | zombie audio graph replacement refused because retirement limit is full"
            )
        case .retirementLimitReached(let reason):
            EventReporter.shared.capture(
                level: .error,
                engine: "parakeet",
                event: "audio_engine_retirement_limit_reached",
                message: "Audio graph replacement stopped at its hard retention limit",
                context: [
                    "reason": reason,
                    "limit": "\(ParakeetAudioEngineRetirementPolicy.maximumRetainedEngineCount)",
                ]
            )
        }
    }
}

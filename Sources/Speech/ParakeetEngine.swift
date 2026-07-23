// ParakeetEngine.swift
// FluidAudio-based STT engine — CoreML Parakeet TDT V3 for batch transcription.
// AVAudioEngine tap → NSLock-batched samples → resampled to 16kHz → AsrManager.transcribe()
// for final batch inference.

import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreAudio
import FluidAudio
import Foundation
import TranscriptedCore

private struct ParakeetSystemInputRestoreTarget: Equatable, Sendable {
    let temporaryInput: AudioDeviceID
    let previousInput: AudioDeviceID
}

private struct ParakeetSystemInputReconciliationRequest: Equatable, Sendable {
    let attemptedTarget: ParakeetSystemInputRestoreTarget
    let clearMarkerWhenRestored: Bool
}

@MainActor
class ParakeetEngine: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var audioLevel: Float = 0
    @Published var modelDownloadState: ParakeetModelState = .notLoaded
    @Published var recordingInterrupted = false
    @Published var isRecovering = false
    @Published var inputFormatReady = true
    private(set) var lastEmptyTranscriptionReason: DictationEmptyTranscriptionReason?

    var hasRecoverableRecording: Bool {
        !recoveredRecordingTimeline.isEmpty
    }

    var audioEngine = AVAudioEngine()
    private var audioEngineQueue = ParakeetEngine.makeAudioEngineQueue()
    private static let systemInputWorkCoordinator = ParakeetReplaceableSystemInputWorkCoordinator(
        label: "com.transcripted.parakeet.system-input"
    )
    var audioGraphGeneration = 0
    private var audioStartAdmission = ParakeetAudioStartAdmissionState()
    var audioStartInProgress: Bool { audioStartAdmission.isInProgress }
    var audioStopInProgress = false
    private var inputTapInstalled = false
    var sharedMeetingMicRecording = false
    private nonisolated let sharedMeetingMicRecorder = SharedMeetingMicRecorder()
    private var sharedMeetingMicTransition = SharedMeetingMicTransitionState()
    private var sampleBuffer: [Float] = []
    private var recoveredRecordingTimeline = RecordedAudioTimeline()
    private var preservingRecordingAcrossRecovery = false
    private nonisolated(unsafe) var nativeSampleRate: Double = 48000
    private nonisolated(unsafe) var audioStartReferenceTime: CFAbsoluteTime?
    private let pendingSamplesLock = NSLock()
    private var pendingSamples: [Float] = []
    private var didReportPendingSampleTruncation = false
    private nonisolated(unsafe) var lastLevelUpdate: CFAbsoluteTime = 0
    var isEnginePrewarmed = false
    private var wakeObserver: NSObjectProtocol?
    var inputDeviceChangeListener: AudioObjectPropertyListenerBlock?
    private var recentAudioEngineRebuildTimestamps: [CFAbsoluteTime] = []
    private var didReportAudioEngineRebuildChurn = false

    var configChangeObserver: NSObjectProtocol?
    var configChangeDebounceTask: Task<Void, Never>?
    var configRecoveryTask: Task<Void, Never>?
    var configRecoveryTimeoutTask: Task<Void, Never>?
    var routeTransitionDebounceState = ParakeetRouteTransitionDebounceState()
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
    var modelInitializationTask: Task<Void, Never>?
    var modelFilePrefetchTask: Task<URL, Error>?
    var prefetchedModelPath: URL?
    private var audioWatchdogTask: Task<Void, Never>?
    private var zombieRecoveryTask: Task<Void, Never>?
    private var zombieRecoveryState = ParakeetZombieRecoveryState()
    let audioEngineWorkOwnership = ParakeetTimedAudioEngineWorkOwnership()
    private var audioStartCancellationState: ParakeetAudioStartCancellationState?
    private var zombieRecoveryStartGeneration: UInt64?
    private var zombieRecoveryRestartPending: Bool { zombieRecoveryState.isActive }
    private var asrInferenceActivity = ParakeetASRInferenceActivityState()
    private var asrInferenceHandoffCount = 0
    private var asrInferenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var pureSampleTranscriptionActivityCount = 0
    var asrManagerReady = false
    private nonisolated(unsafe) var didReceiveAudioSamples = false
    private nonisolated(unsafe) var didReceiveNonZeroAudioSamples = false
    private var recordingStartedOnLikelyBluetoothHandsFreeRoute = false
    var cachedInputDeviceName = "Unknown"
    /// Last known dictation input selection, refreshed on start, prewarm,
    /// route/device-change notifications, and background refreshes. Serves
    /// analytics callers without a live CoreAudio device enumeration.
    var cachedInputDeviceSelection: DictationInputDeviceSelection?
    private var lastAudioStartFailureReportAt: TimeInterval?
    private var lastInputSelectionReportKey: String?
    var ignoreInputSelectionConfigChangesUntil: CFAbsoluteTime = 0
    private var pendingSystemInputRestore = ParakeetOwnerBoundPendingState<ParakeetSystemInputRestoreTarget>()
    private var pendingSystemInputReconciliations: [ParakeetSystemInputReconciliationRequest] = []
    private var systemInputReconciliationTask: Task<Void, Never>?

    var isModelLoaded: Bool { asrManagerReady }
    var inputDeviceName: String { cachedInputDeviceName }
    var isRecordingFromSharedMeetingMic: Bool { sharedMeetingMicRecording }

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
        if asrManagerReady { return true }
        switch modelDownloadState {
        case .downloading, .failed:
            return false
        case .notLoaded, .cached, .loading, .ready:
            return prefetchedModelPath != nil || hasBundledParakeetModel
        }
    }

    private lazy var hasBundledParakeetModel: Bool =
        bundledModelPath(
            subdirectory: "parakeet-tdt-0.6b-v3",
            checkFile: "JointDecisionv3.mlmodelc"
        ) != nil ||
        bundledModelPath(
            subdirectory: "parakeet-tdt-0.6b-v3-coreml",
            checkFile: "Encoder.mlmodelc"
        ) != nil

    init() {
        markCachedRuntimeModelIfAvailable()
        scheduleInputDeviceNameRefresh()
    }

    private static func makeAudioEngineQueue() -> DispatchQueue {
        DispatchQueue(label: "com.transcripted.parakeet.audio-engine", qos: .userInitiated)
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

    nonisolated private static func applyPreferredSystemInputDevice(
        for selection: DictationInputDeviceSelection?
    ) -> String? {
        guard let selection,
              selection.didOverrideDefault,
              selection.reason == .preferredBuiltInForBluetoothHeadset else {
            return nil
        }

        do {
            try CoreAudioInputDeviceLookup.setDefaultInputDeviceID(selection.selectedInput.id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    nonisolated private static func restoreSystemInputDeviceIfStillTemporary(
        temporaryInput: AudioDeviceID,
        previousInput: AudioDeviceID
    ) -> String? {
        do {
            let currentInput = try CoreAudioInputDeviceLookup.currentDefaultInputDeviceID()
            guard currentInput == temporaryInput else {
                return nil
            }
            try CoreAudioInputDeviceLookup.setDefaultInputDeviceID(previousInput)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    nonisolated private static func applySystemInputDevice(_ input: AudioDeviceID) -> String? {
        do {
            try CoreAudioInputDeviceLookup.setDefaultInputDeviceID(input)
            return nil
        } catch {
            return error.localizedDescription
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

    func scheduleInputDeviceNameRefresh() {
        Task.detached(priority: .utility) { [weak self] in
            if let selection = Self.loadDictationInputDeviceSelection() {
                await self?.updateCachedInputDeviceSelection(selection)
            } else {
                await self?.updateCachedInputDeviceName("Unknown")
            }
        }
    }

    private func runAudioEngineWork<T>(_ work: @escaping (AVAudioEngine) throws -> T) async throws -> T {
        let queue = audioEngineQueue
        let engine = audioEngine
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work(engine))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runTimedAudioEngineWork<T>(
        operation: String,
        timeoutNanoseconds: UInt64 = TranscriptedConstants.audioStartOperationTimeout,
        isWorkCurrent: (() -> Bool)? = nil,
        cleanupAfterCancellation: ((AVAudioEngine) -> Void)? = nil,
        cleanupAfterLateCompletion: ((AVAudioEngine) -> Void)? = nil,
        _ work: @escaping (AVAudioEngine) throws -> T
    ) async throws -> T {
        let queue = audioEngineQueue
        let engine = audioEngine
        let timeoutMs = Int(timeoutNanoseconds / 1_000_000)
        let resumeLock = NSLock()
        var didResume = false

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            func resumeOnce(_ result: Result<T, Error>) {
                var shouldResume = false
                resumeLock.withLock {
                    if !didResume {
                        didResume = true
                        shouldResume = true
                    }
                }
                guard shouldResume else { return }
                continuation.resume(with: result)
            }

            queue.async {
                let shouldRun = resumeLock.withLock { !didResume }
                guard shouldRun else { return }
                guard isWorkCurrent?() != false else {
                    resumeOnce(.failure(CancellationError()))
                    return
                }

                var result: Result<T, Error>
                do {
                    result = .success(try work(engine))
                } catch {
                    result = .failure(error)
                }

                let workStayedCurrent = isWorkCurrent?() != false
                if !workStayedCurrent {
                    cleanupAfterCancellation?(engine)
                    result = .failure(CancellationError())
                }

                var completedBeforeTimeout = false
                resumeLock.withLock {
                    if !didResume {
                        didResume = true
                        completedBeforeTimeout = true
                    }
                }

                if completedBeforeTimeout {
                    continuation.resume(with: result)
                } else if !workStayedCurrent {
                    // Cancellation cleanup already ran synchronously on this
                    // worker before any successor can use the replacement graph.
                } else {
                    cleanupAfterLateCompletion?(engine)
                }
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))
            ) {
                resumeOnce(
                    .failure(
                        ParakeetAudioEngineWorkError.timedOut(
                            operation: operation,
                            timeoutMs: timeoutMs
                        )
                    )
                )
            }
        }
    }

    private static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Int {
        max(0, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
    }

    private static func timingContext(_ timings: [String: Int]) -> [String: String] {
        timings.reduce(into: [:]) { context, entry in
            context[entry.key] = "\(entry.value)"
        }
    }

    /// Remove the input tap without tripping AVAudioEngine's
    /// `required condition is false: isSink || tap != nullptr` assertion.
    ///
    /// Removing a tap while the engine is still running leaves the input node
    /// with neither a tap nor a downstream sink; the next IO-thread
    /// `InputAvailable` callback then crashes the process. Stop the engine and
    /// let in-flight input callbacks drain BEFORE removing the tap, mirroring
    /// the meeting/mic path's `Audio.tearDownInputTapSafely` via the shared
    /// `AudioInputTapTeardownPolicy`.
    ///
    /// Must be called on `audioEngineQueue` (callers already hop there); the
    /// drain step briefly blocks that queue, never the CoreAudio render thread.
    private nonisolated static func safelyRemoveInputTap(on audioEngine: AVAudioEngine) {
        for step in AudioInputTapTeardownPolicy.steps(engineIsRunning: audioEngine.isRunning) {
            switch step {
            case .stopEngine:
                audioEngine.stop()
            case .waitForStoppedInputCallbacks:
                Thread.sleep(forTimeInterval: AudioInputTapTeardownPolicy.inputCallbackDrainDelay)
            case .removeInputTap:
                audioEngine.inputNode.removeTap(onBus: 0)
            }
        }
    }

    private nonisolated static func cleanUpLateAudioStart(on audioEngine: AVAudioEngine) {
        safelyRemoveInputTap(on: audioEngine)
        audioEngine.reset()
    }

    private func runAudioEngineWork<T>(_ work: @escaping (AVAudioEngine) -> T) async -> T {
        let queue = audioEngineQueue
        let engine = audioEngine
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work(engine))
            }
        }
    }

    private func updateCachedInputDeviceName(_ deviceName: String) {
        cachedInputDeviceName = deviceName
    }

    func updateCachedInputDeviceSelection(_ selection: DictationInputDeviceSelection) {
        cachedInputDeviceName = selection.selectedInput.name
        cachedInputDeviceSelection = selection
        routeTransitionDebounceState.seedStableRouteIfNeeded(
            categoricalAudioRoute(for: selection)
        )
    }

    func categoricalAudioRoute(
        for selection: DictationInputDeviceSelection
    ) -> ParakeetCategoricalAudioRoute {
        let context = dictationRouteAnalyticsContext(selection: selection)
        return ParakeetCategoricalAudioRoute(
            inputDeviceClass: context["input_device_class"] ?? "unknown",
            outputDeviceClass: context["output_device_class"] ?? "unknown",
            routeShape: context["route_shape"] ?? "unknown"
        )
    }

    // MARK: - Input readiness

    func prewarm() async {
        guard !Task.isCancelled else { return }
        guard !isShuttingDown else { return }
        guard !isRecording else { return }
        guard !audioStartInProgress else { return }
        installAudioObserversIfNeeded()
        scheduleInputDeviceNameRefresh()

        await releaseIdleAudioHardware(removeTap: false)
        guard !Task.isCancelled else { return }
        let prewarmOwner = currentAudioEngineQueueOwnerToken()
        guard canContinuePrewarm(owner: prewarmOwner) else { return }

        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch ParakeetPrewarmPolicy.decision(for: microphoneStatus) {
        case .proceed:
            break
        case .skip(let level, let event, let message, let context):
            let eventLevel: EventLevel
            switch level {
            case .info:
                eventLevel = .info
            case .warning:
                eventLevel = .warning
            }
            EventReporter.shared.capture(
                level: eventLevel,
                engine: "parakeet",
                event: event,
                message: message,
                context: context
            )
            return
        }

        let prewarmSelection = await Task.detached(priority: .utility) {
            Self.loadDictationInputDeviceSelection()
        }.value
        guard canContinuePrewarm(owner: prewarmOwner) else { return }
        if ParakeetPrewarmPolicy.shouldDeferHardwarePrewarm(for: prewarmSelection) {
            if let prewarmSelection {
                updateCachedInputDeviceSelection(prewarmSelection)
            }
            prewarmRetryCount = 0
            markFormatReadyAndPublish()
            EventReporter.shared.capture(
                level: .info,
                engine: "parakeet",
                event: "prewarm_deferred_for_bluetooth_fallback",
                message: "Deferred idle microphone graph changes until dictation starts",
                context: dictationRouteDiagnosticsContext(selection: prewarmSelection)
            )
            return
        }

        let snapshot: ParakeetAudioInputSnapshot
        do {
            snapshot = try await audioInputSnapshot(operation: "prewarm")
        } catch {
            guard canContinuePrewarm(owner: prewarmOwner) else { return }
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "prewarm_failed",
                message: error.localizedDescription
            )
            markFormatUnreadyAndPublish()
            schedulePrewarmRetry()
            return
        }
        guard canContinuePrewarm(owner: prewarmOwner) else { return }

        // Validate both formats. AirPods on macOS run input in Hands-Free Profile
        // (24kHz hw / 48kHz output bus); CoreAudio's internal converter handles
        // the upsample and the tap delivers at the output bus rate. Both must be
        // valid before declaring the engine ready — input alone or output alone
        // can transiently report zero during device transitions.
        let readiness = audioFormatReadiness(
            outputFormat: snapshot.outputFormat,
            hwFormat: snapshot.hwFormat,
            selection: snapshot.selection
        )
        guard readiness == .ready else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "prewarm_invalid_format",
                message: "Audio format invalid during prewarm",
                context: audioFormatContext(
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat,
                    selection: snapshot.selection,
                    readiness: readiness
                ))
            // Do NOT rebuild the engine here, even for .routeNotSettled. The override
            // this snapshot just applied (built-in mic instead of a Bluetooth headset)
            // lives on this engine's AUHAL; discarding the engine forces the next
            // snapshot to touch the AirPods mic again to rebind the AUHAL to the
            // system default before re-applying the override — audibly bumping the
            // Bluetooth route on every retry and racing settling with churn instead
            // of waiting it out. Keep the engine and let schedulePrewarmRetry() poll;
            // applyPreferredDictationInputDevice() is a no-op once the deviceID already
            // matches, so retries here are cheap format reads with no route touch.
            markFormatUnreadyAndPublish()
            schedulePrewarmRetry()
            return
        }

        updateNativeSampleRate(snapshot.outputFormat.sampleRate)

        prewarmRetryCount = 0
        markFormatReadyAndPublish()
        AppLogger.transcription.info("PARAKEET | input ready (\(inputDeviceName), \(safeNativeSampleRate())Hz)")
    }

    private func canContinuePrewarm(owner: ParakeetAudioEngineQueueOwnerToken) -> Bool {
        !isShuttingDown
            && !isRecording
            && !audioStartInProgress
            && ownsAudioEngineQueue(owner)
    }

    func schedulePrewarmRetry() {
        guard !isShuttingDown else { return }
        // Bounded retry — give CoreAudio time to settle, but don't loop forever.
        // Each call counts toward the budget; budget resets on a successful prewarm
        // or on an explicit device change (which restarts the cycle anyway).
        guard prewarmRetryCount < TranscriptedConstants.prewarmRetryBudget else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet",
                event: "prewarm_retry_budget_exhausted",
                message: "Prewarm retry budget exhausted — engine will retry on next device change or user action",
                context: ["audio_device": inputDeviceName])
            prewarmRetryCount = 0
            return
        }
        prewarmRetryCount += 1
        let capturedGeneration = recoveryState.generation
        prewarmRetryTask?.cancel()
        prewarmRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
            guard !Task.isCancelled,
                  let self,
                  !self.isShuttingDown,
                  !self.recoveryState.isStale(generation: capturedGeneration) else { return }
            await self.prewarm()
        }
    }

    func forceInputReadinessRecovery(reason: String) async {
        guard !Task.isCancelled else { return }
        guard !isShuttingDown else { return }
        guard !isRecording, !audioStartInProgress else { return }

        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        prewarmRetryCount = 0

        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "input_readiness_recovery_forced",
            message: "Forced idle audio graph recovery while waiting for dictation input readiness",
            context: [
                "reason": reason,
                "recovering": "\(recoveryState.isRecovering)",
                "format_ready": "\(recoveryState.inputFormatReady)",
                "generation": "\(recoveryState.generation)",
            ]
        )

        abandonBlockedAudioEngine(reason: reason)
        markFormatUnreadyAndPublish()
        do {
            try await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        await prewarm()
    }

    private func installAudioObserversIfNeeded() {
        installAudioEngineConfigObserverIfNeeded()

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

    func publishRecoveryState() {
        isRecovering = recoveryState.isRecovering
        inputFormatReady = recoveryState.inputFormatReady
    }

    private func markFormatUnreadyAndPublish() {
        recoveryState.markFormatUnready()
        publishRecoveryState()
    }

    private func markStartFailedAndPublish() {
        recoveryState.markStartFailed()
        publishRecoveryState()
    }

    private func markFormatReadyAndPublish() {
        if !recoveryState.inputFormatReady {
            recoveryState.markFormatReady()
            publishRecoveryState()
        }
    }

    private nonisolated static func audioFormatSummary(_ format: AVAudioFormat) -> ParakeetAudioFormatSummary {
        ParakeetAudioFormatSummary(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount
        )
    }

    func safeNativeSampleRate() -> Double {
        ParakeetAudioFormatReadinessPolicy.captureSampleRateOrFallback(nativeSampleRate)
    }

    func updateNativeSampleRate(_ sampleRate: Double) {
        nativeSampleRate = ParakeetAudioFormatReadinessPolicy.captureSampleRateOrFallback(sampleRate)
    }

    private func reserveNativeSampleBufferCapacity() {
        let capacity = ParakeetAudioFormatReadinessPolicy.bufferCapacitySampleCount(
            sampleRate: safeNativeSampleRate(),
            seconds: TranscriptedConstants.audioBufferCapacitySeconds
        )
        sampleBuffer.reserveCapacity(capacity)
        // The tap thread appends into pendingSamples for the whole session
        // (drain happens at stop), so reserve the same capacity up front to
        // avoid growth reallocations while audio is flowing.
        pendingSamplesLock.withLock {
            pendingSamples.reserveCapacity(capacity)
        }
    }

    func audioFormatReadiness(
        outputFormat: ParakeetAudioFormatSummary,
        hwFormat: ParakeetAudioFormatSummary,
        selection: DictationInputDeviceSelection?
    ) -> ParakeetAudioFormatReadiness {
        ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: outputFormat.sampleRate,
            outputChannelCount: outputFormat.channelCount,
            inputSampleRate: hwFormat.sampleRate,
            inputChannelCount: hwFormat.channelCount,
            selectedInputClass: selectedInputClass(for: selection),
            outputDeviceClass: defaultOutputClass(for: selection),
            selectionOverrodeDefault: selection?.didOverrideDefault ?? false,
            selectionReason: selection?.reason
        )
    }

    private func selectedInputClass(for selection: DictationInputDeviceSelection?) -> String {
        if let selection {
            return DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput)
        }
        return inputDeviceClass(for: inputDeviceName)
    }

    private func defaultOutputClass(for selection: DictationInputDeviceSelection?) -> String {
        selection?.defaultOutput.map(DictationInputDeviceSelectionPolicy.deviceClass(for:)) ?? "unknown"
    }

    func audioFormatContext(
        outputFormat: ParakeetAudioFormatSummary,
        hwFormat: ParakeetAudioFormatSummary,
        selection: DictationInputDeviceSelection?,
        readiness: ParakeetAudioFormatReadiness
    ) -> [String: String] {
        var context = [
            "format_readiness": readiness.rawValue,
            "output_rate_hz": String(format: "%.0f", outputFormat.sampleRate),
            "output_channels": "\(outputFormat.channelCount)",
            "input_rate_hz": String(format: "%.0f", hwFormat.sampleRate),
            "hw_channels": "\(hwFormat.channelCount)",
            "input_device_class": selectedInputClass(for: selection),
            "selection_overrode_default": "\(selection?.didOverrideDefault ?? false)",
            "recovering": "\(recoveryState.isRecovering)",
            "format_ready": "\(recoveryState.inputFormatReady)",
            "generation": "\(recoveryState.generation)",
        ]

        if let selection {
            context["selection_reason"] = selection.reason.rawValue
            context["default_input_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput)
            context["selected_input_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput)
            if let defaultOutput = selection.defaultOutput {
                context["default_output_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: defaultOutput)
            }
        }

        return context
    }

    func dictationRouteDiagnosticsContext(
        outputFormat: ParakeetAudioFormatSummary? = nil,
        hwFormat: ParakeetAudioFormatSummary? = nil,
        selection: DictationInputDeviceSelection?,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var context = dictationRouteAnalyticsContext(
            outputFormat: outputFormat,
            hwFormat: hwFormat,
            selection: selection
        )
        context["recovering"] = "\(recoveryState.isRecovering)"
        context["format_ready"] = "\(recoveryState.inputFormatReady)"
        context["generation"] = "\(recoveryState.generation)"

        for (key, value) in extra {
            context[key] = value
        }

        return context
    }

    func dictationRouteAnalyticsContext(
        outputFormat: ParakeetAudioFormatSummary? = nil,
        hwFormat: ParakeetAudioFormatSummary? = nil,
        selection: DictationInputDeviceSelection?,
        extra: [String: String] = [:]
    ) -> [String: String] {
        let selectedClass = selectedInputClass(for: selection)
        let defaultInputClass = selection.map { DictationInputDeviceSelectionPolicy.deviceClass(for: $0.defaultInput) } ?? "unknown"
        let defaultOutputClass = selection?.defaultOutput.map { DictationInputDeviceSelectionPolicy.deviceClass(for: $0) } ?? "unknown"
        let outputRate = outputFormat?.sampleRate
        let inputRate = hwFormat?.sampleRate

        var context: [String: String] = [
            "default_input_class": defaultInputClass,
            "default_output_class": defaultOutputClass,
            "format_ready": "\(recoveryState.inputFormatReady)",
            "hfp_suspected": "\(ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(inputClass: selectedClass, outputDeviceClass: defaultOutputClass, inputRate: inputRate, outputRate: outputRate))",
            "input_device_class": selectedClass,
            "output_device_class": defaultOutputClass,
            "recovering": "\(recoveryState.isRecovering)",
            "route_shape": ParakeetRouteDiagnosticsPolicy.routeShape(
                selectedInputClass: selectedClass,
                outputDeviceClass: defaultOutputClass
            ),
            "sample_flow_started": "\(didReceiveAudioSamples)",
            "sample_signal_started": "\(didReceiveNonZeroAudioSamples)",
            "selection_overrode_default": "\(selection?.didOverrideDefault ?? false)",
            "selection_reason": selection?.reason.rawValue ?? "unknown",
            "selected_input_class": selectedClass,
        ]

        if let outputFormat {
            context["output_rate_hz"] = String(format: "%.0f", outputFormat.sampleRate)
            context["output_channels"] = "\(outputFormat.channelCount)"
        }

        if let hwFormat {
            context["input_rate_hz"] = String(format: "%.0f", hwFormat.sampleRate)
            context["input_channels"] = "\(hwFormat.channelCount)"
        }

        for (key, value) in extra {
            context[key] = value
        }

        return context
    }

    private func restoreSystemInputIfStillTemporary(
        temporaryInput: AudioDeviceID,
        previousInput: AudioDeviceID,
        operation: String
    ) async {
        ignoreInputSelectionConfigChangesUntil = CFAbsoluteTimeGetCurrent()
            + TranscriptedConstants.selfInducedConfigChangeIgnoreWindow
        let restoreTarget = ParakeetSystemInputRestoreTarget(
            temporaryInput: temporaryInput,
            previousInput: previousInput
        )
        let restoreError: String?
        do {
            restoreError = try await Self.systemInputWorkCoordinator.run(
                operation: operation,
                timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout,
                cleanupAfterLateCompletion: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        await self?.reconcileSystemInputAfterLateCompletion(
                            attemptedTarget: restoreTarget,
                            clearMarkerWhenRestored: true
                        )
                    }
                }
            ) {
                Self.restoreSystemInputDeviceIfStillTemporary(
                    temporaryInput: temporaryInput,
                    previousInput: previousInput
                )
            }
        } catch {
            reportSystemInputRestoreFailure(operation: operation, failureKind: "timeout")
            await reconcileSystemInputAfterLateCompletion(
                attemptedTarget: restoreTarget,
                clearMarkerWhenRestored: false
            )
            return
        }
        if restoreError != nil {
            reportSystemInputRestoreFailure(
                operation: operation,
                failureKind: "core_audio_error"
            )
        } else {
            if !pendingSystemInputRestore.hasPendingValue {
                DictationPersistentInputPreferences.setTemporaryRecoveryMarker(nil)
            }
        }
    }

    private func restorePendingSystemInputAfterRecording(
        ownedBy owner: ParakeetAudioGraphOwnerToken?,
        operation: String
    ) async {
        guard let owner,
              let restoreTarget = pendingSystemInputRestore.take(ownedBy: owner) else { return }
        await restoreSystemInputIfStillTemporary(
            temporaryInput: restoreTarget.temporaryInput,
            previousInput: restoreTarget.previousInput,
            operation: operation
        )
    }

    private func reportSystemInputRestoreFailure(
        operation: String,
        failureKind: String
    ) {
        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "dictation_system_input_restore_failed",
            message: "Failed to restore system input after dictation route override",
            context: [
                "operation": operation,
                "failure_kind": failureKind,
            ]
        )
    }

    /// A timed-out CoreAudio write can finish after its queue has been retired.
    /// Re-apply the latest owner intent, or restore the attempted route when no
    /// successor exists, so late completion converges on current MainActor state.
    private func reconcileSystemInputAfterLateCompletion(
        attemptedTarget: ParakeetSystemInputRestoreTarget,
        clearMarkerWhenRestored: Bool
    ) async {
        enqueueSystemInputReconciliation(
            ParakeetSystemInputReconciliationRequest(
                attemptedTarget: attemptedTarget,
                clearMarkerWhenRestored: clearMarkerWhenRestored
            )
        )
        if let systemInputReconciliationTask {
            await systemInputReconciliationTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainSystemInputReconciliations()
        }
        systemInputReconciliationTask = task
        await task.value
    }

    private func enqueueSystemInputReconciliation(
        _ request: ParakeetSystemInputReconciliationRequest
    ) {
        if let existingIndex = pendingSystemInputReconciliations.firstIndex(where: {
            $0.attemptedTarget == request.attemptedTarget
        }) {
            let existing = pendingSystemInputReconciliations[existingIndex]
            pendingSystemInputReconciliations[existingIndex] = ParakeetSystemInputReconciliationRequest(
                attemptedTarget: request.attemptedTarget,
                clearMarkerWhenRestored: existing.clearMarkerWhenRestored || request.clearMarkerWhenRestored
            )
        } else {
            pendingSystemInputReconciliations.append(request)
        }
    }

    private func drainSystemInputReconciliations() async {
        while !pendingSystemInputReconciliations.isEmpty {
            let request = pendingSystemInputReconciliations.removeFirst()
            await performSystemInputReconciliation(request)
        }
        systemInputReconciliationTask = nil
    }

    private func performSystemInputReconciliation(
        _ request: ParakeetSystemInputReconciliationRequest
    ) async {
        for _ in 0..<TranscriptedConstants.systemInputReconciliationAttempts {
            if let successorOwner = pendingSystemInputRestore.owner,
               let successorTarget = pendingSystemInputRestore.value(ownedBy: successorOwner) {
                let applyError: String?
                do {
                    applyError = try await Self.systemInputWorkCoordinator.run(
                        operation: "late_completion_successor_reconcile",
                        timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout,
                        cleanupAfterLateCompletion: { [weak self] lateError in
                            Task { @MainActor [weak self] in
                                await self?.handleLateSystemInputReconciliationCompletion(
                                    coreAudioError: lateError,
                                    intendedOwner: successorOwner,
                                    intendedTarget: successorTarget,
                                    request: request
                                )
                            }
                        }
                    ) {
                        Self.applySystemInputDevice(successorTarget.temporaryInput)
                    }
                } catch {
                    reportSystemInputRestoreFailure(
                        operation: "late_completion_successor_reconcile",
                        failureKind: "timeout"
                    )
                    continue
                }
                guard applyError == nil else {
                    reportSystemInputRestoreFailure(
                        operation: "late_completion_successor_reconcile",
                        failureKind: "core_audio_error"
                    )
                    continue
                }
                if pendingSystemInputRestore.owner == successorOwner,
                   pendingSystemInputRestore.value(ownedBy: successorOwner) == successorTarget {
                    return
                }
                continue
            }

            let restoreError: String?
            do {
                restoreError = try await Self.systemInputWorkCoordinator.run(
                    operation: "late_completion_restore_reconcile",
                    timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout,
                    cleanupAfterLateCompletion: { [weak self] lateError in
                        Task { @MainActor [weak self] in
                            await self?.handleLateSystemInputReconciliationCompletion(
                                coreAudioError: lateError,
                                intendedOwner: nil,
                                intendedTarget: nil,
                                request: request
                            )
                        }
                    }
                ) {
                    Self.restoreSystemInputDeviceIfStillTemporary(
                        temporaryInput: request.attemptedTarget.temporaryInput,
                        previousInput: request.attemptedTarget.previousInput
                    )
                }
            } catch {
                reportSystemInputRestoreFailure(
                    operation: "late_completion_restore_reconcile",
                    failureKind: "timeout"
                )
                continue
            }
            guard restoreError == nil else {
                reportSystemInputRestoreFailure(
                    operation: "late_completion_restore_reconcile",
                    failureKind: "core_audio_error"
                )
                continue
            }
            if !pendingSystemInputRestore.hasPendingValue {
                if request.clearMarkerWhenRestored {
                    DictationPersistentInputPreferences.setTemporaryRecoveryMarker(nil)
                }
                return
            }
        }
    }

    /// Timed-out reconciliation work may complete after a replacement queue has
    /// already converged the route. The late result needs more work only when
    /// MainActor intent changed while that HAL call was blocked. An unchanged
    /// successful intent is terminal, which prevents timeout callbacks from
    /// recursively creating an unbounded queue/task chain.
    private func handleLateSystemInputReconciliationCompletion(
        coreAudioError: String?,
        intendedOwner: ParakeetAudioGraphOwnerToken?,
        intendedTarget: ParakeetSystemInputRestoreTarget?,
        request: ParakeetSystemInputReconciliationRequest
    ) async {
        guard coreAudioError == nil else {
            reportSystemInputRestoreFailure(
                operation: intendedOwner == nil
                    ? "late_completion_restore_reconcile"
                    : "late_completion_successor_reconcile",
                failureKind: "core_audio_error"
            )
            return
        }

        if let intendedOwner, let intendedTarget {
            if pendingSystemInputRestore.owner == intendedOwner,
               pendingSystemInputRestore.value(ownedBy: intendedOwner) == intendedTarget {
                return
            }
        } else if !pendingSystemInputRestore.hasPendingValue {
            if request.clearMarkerWhenRestored {
                DictationPersistentInputPreferences.setTemporaryRecoveryMarker(nil)
            }
            return
        }

        await reconcileSystemInputAfterLateCompletion(
            attemptedTarget: request.attemptedTarget,
            clearMarkerWhenRestored: true
        )
    }

    private func schedulePendingSystemInputRestore(
        ownedBy owner: ParakeetAudioGraphOwnerToken?,
        operation: String
    ) {
        guard let owner,
              let restoreTarget = pendingSystemInputRestore.take(ownedBy: owner) else { return }
        ignoreInputSelectionConfigChangesUntil = CFAbsoluteTimeGetCurrent()
            + TranscriptedConstants.selfInducedConfigChangeIgnoreWindow
        Self.systemInputWorkCoordinator.schedule(
            operation: operation,
            timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout,
            cleanupAfterLateCompletion: { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.reconcileSystemInputAfterLateCompletion(
                        attemptedTarget: restoreTarget,
                        clearMarkerWhenRestored: true
                    )
                }
            },
            completion: { [weak self] (result: Result<String?, Error>) in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch result {
                    case .failure:
                        self.reportSystemInputRestoreFailure(
                            operation: operation,
                            failureKind: "timeout"
                        )
                        await self.reconcileSystemInputAfterLateCompletion(
                            attemptedTarget: restoreTarget,
                            clearMarkerWhenRestored: false
                        )
                    case .success(let restoreError):
                        if restoreError != nil {
                            self.reportSystemInputRestoreFailure(
                                operation: operation,
                                failureKind: "core_audio_error"
                            )
                        } else if !self.pendingSystemInputRestore.hasPendingValue {
                            DictationPersistentInputPreferences.setTemporaryRecoveryMarker(nil)
                        }
                    }
                }
            }
        ) {
            let restoreError = Self.restoreSystemInputDeviceIfStillTemporary(
                temporaryInput: restoreTarget.temporaryInput,
                previousInput: restoreTarget.previousInput
            )
            return restoreError
        }
    }

    func audioInputSnapshot(
        operation: String,
        recoveryGeneration: UInt64? = nil,
        allowsBuiltInBluetoothFallback: Bool = true,
        isEngineWorkCurrent: (() -> Bool)? = nil
    ) async throws -> ParakeetAudioInputSnapshot {
        let operationOwner = currentAudioEngineQueueOwnerToken()
        let snapshotStartedAt = CFAbsoluteTimeGetCurrent()
        let selectionStartedAt = CFAbsoluteTimeGetCurrent()
        let selection = try await Self.systemInputWorkCoordinator.run(
            operation: "\(operation)_selection",
            timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout
        ) {
            Self.loadDictationInputDeviceSelection(
                allowsBuiltInBluetoothFallback: allowsBuiltInBluetoothFallback
            )
        }
        guard ownsAudioEngineQueue(operationOwner) else { throw CancellationError() }
        var stageTimings = [
            "audio_input_selection_load_ms": Self.elapsedMilliseconds(since: selectionStartedAt)
        ]
        if let selection, selection.didOverrideDefault {
            // Avoid touching the current default input before the override is applied.
            // On AirPods routes, even a short read of the default input can briefly
            // pull playback toward headset-mode audio.
            ignoreInputSelectionConfigChangesUntil = CFAbsoluteTimeGetCurrent()
                + TranscriptedConstants.selfInducedConfigChangeIgnoreWindow
        }
        let shouldRestoreSystemInputOnStop = operation == "start_recording"
        let recoveryMarker = selection.flatMap { selection -> DictationPersistentInputPreferences.RecoveryMarker? in
            guard selection.didOverrideDefault,
                  selection.reason == .preferredBuiltInForBluetoothHeadset,
                  let selectedUID = selection.selectedInput.uid,
                  let previousUID = selection.defaultInput.uid else {
                return nil
            }
            return DictationPersistentInputPreferences.RecoveryMarker(
                selectedUID: selectedUID,
                previousUID: previousUID
            )
        }
        if let recoveryMarker {
            DictationPersistentInputPreferences.setTemporaryRecoveryMarker(recoveryMarker)
        }
        let systemInputOverrideOwner = operationOwner.graphOwner
        let systemInputRestoreTarget = selection.flatMap { selection -> ParakeetSystemInputRestoreTarget? in
            guard selection.didOverrideDefault,
                  selection.reason == .preferredBuiltInForBluetoothHeadset else { return nil }
            return ParakeetSystemInputRestoreTarget(
                temporaryInput: selection.selectedInput.id,
                previousInput: selection.defaultInput.id
            )
        }
        if let systemInputRestoreTarget {
            pendingSystemInputRestore.replace(
                systemInputRestoreTarget,
                ownedBy: systemInputOverrideOwner
            )
        }
        let systemInputOverrideStartedAt = CFAbsoluteTimeGetCurrent()
        let systemInputOverrideError: String?
        do {
            systemInputOverrideError = try await Self.systemInputWorkCoordinator.run(
                operation: "\(operation)_system_input_apply",
                timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout,
                cleanupAfterLateCompletion: { [weak self] _ in
                    guard let systemInputRestoreTarget else { return }
                    Task { @MainActor [weak self] in
                        await self?.reconcileSystemInputAfterLateCompletion(
                            attemptedTarget: systemInputRestoreTarget,
                            clearMarkerWhenRestored: true
                        )
                    }
                }
            ) {
                Self.applyPreferredSystemInputDevice(for: selection)
            }
        } catch {
            if let restoreTarget = pendingSystemInputRestore.take(ownedBy: systemInputOverrideOwner) {
                await reconcileSystemInputAfterLateCompletion(
                    attemptedTarget: restoreTarget,
                    clearMarkerWhenRestored: false
                )
            }
            throw error
        }
        func restoreSystemInputAfterOwnershipLoss(stage: String) async {
            guard systemInputOverrideError == nil,
                  let systemInputRestoreTarget = pendingSystemInputRestore.take(
                    ownedBy: systemInputOverrideOwner
                  ) else { return }
            await restoreSystemInputIfStillTemporary(
                temporaryInput: systemInputRestoreTarget.temporaryInput,
                previousInput: systemInputRestoreTarget.previousInput,
                operation: "\(operation)_system_input_stale_\(stage)"
            )
        }
        func restoreSystemInputAfterNonRecordingUse(operation restoreOperation: String) async {
            guard !shouldRestoreSystemInputOnStop,
                  let systemInputRestoreTarget = pendingSystemInputRestore.take(
                    ownedBy: systemInputOverrideOwner
                  ) else { return }
            await restoreSystemInputIfStillTemporary(
                temporaryInput: systemInputRestoreTarget.temporaryInput,
                previousInput: systemInputRestoreTarget.previousInput,
                operation: restoreOperation
            )
        }
        guard ownsAudioEngineQueue(operationOwner) else {
            await restoreSystemInputAfterOwnershipLoss(stage: "override")
            throw CancellationError()
        }
        stageTimings["audio_input_system_override_ms"] = Self.elapsedMilliseconds(since: systemInputOverrideStartedAt)
        if let selection, selection.didOverrideDefault {
            var context = inputSelectionContext(selection, operation: "\(operation)_system_input")
            if let systemInputOverrideError {
                pendingSystemInputRestore.clear(ownedBy: systemInputOverrideOwner)
                if recoveryMarker != nil {
                    DictationPersistentInputPreferences.setTemporaryRecoveryMarker(nil)
                }
                context["error"] = systemInputOverrideError
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "dictation_system_input_override_failed",
                    message: "Failed to move system input away from Bluetooth headset microphone",
                    context: context
                )
            } else if selection.reason == .preferredBuiltInForBluetoothHeadset {
                EventReporter.shared.capture(
                    level: .info,
                    engine: "parakeet",
                    event: "dictation_system_input_auto_selected",
                    message: "System input moved away from Bluetooth headset microphone",
                    context: context
                )
            }
        }

        if let recoveryGeneration, recoveryState.isStale(generation: recoveryGeneration) {
            await restoreSystemInputAfterNonRecordingUse(
                operation: "\(operation)_system_input_stale_recovery"
            )
            throw CancellationError()
        }
        let snapshotReadStartedAt = CFAbsoluteTimeGetCurrent()
        let snapshotResult: (
            outputFormat: ParakeetAudioFormatSummary,
            hwFormat: ParakeetAudioFormatSummary,
            selectionApplication: ParakeetInputDeviceApplication?,
            engineWasRunning: Bool
        )
        do {
            snapshotResult = try await runTimedAudioEngineWork(
                operation: "\(operation)_snapshot",
                isWorkCurrent: isEngineWorkCurrent
            ) { audioEngine in
                let inputNode = audioEngine.inputNode
                let selectionApplication = Self.applyPreferredDictationInputDevice(selection, to: inputNode)
                return (
                    outputFormat: Self.audioFormatSummary(inputNode.outputFormat(forBus: 0)),
                    hwFormat: Self.audioFormatSummary(inputNode.inputFormat(forBus: 0)),
                    selectionApplication: selectionApplication,
                    engineWasRunning: audioEngine.isRunning
                )
            }
        } catch {
            guard ownsAudioEngineQueue(operationOwner) else {
                await restoreSystemInputAfterOwnershipLoss(stage: "snapshot_failure")
                throw CancellationError()
            }
            await restoreSystemInputAfterNonRecordingUse(
                operation: "\(operation)_system_input_failed"
            )
            throw error
        }
        guard ownsAudioEngineQueue(operationOwner) else {
            await restoreSystemInputAfterOwnershipLoss(stage: "snapshot_success")
            throw CancellationError()
        }
        await restoreSystemInputAfterNonRecordingUse(
            operation: "\(operation)_system_input"
        )
        stageTimings["audio_input_snapshot_read_ms"] = Self.elapsedMilliseconds(since: snapshotReadStartedAt)
        stageTimings["audio_input_total_ms"] = Self.elapsedMilliseconds(since: snapshotStartedAt)
        let snapshot = ParakeetAudioInputSnapshot(
            outputFormat: snapshotResult.outputFormat,
            hwFormat: snapshotResult.hwFormat,
            selection: selection,
            selectionApplication: snapshotResult.selectionApplication,
            engineWasRunning: snapshotResult.engineWasRunning,
            stageTimings: stageTimings
        )
        if let recoveryGeneration, recoveryState.isStale(generation: recoveryGeneration) {
            throw CancellationError()
        }
        guard ownsAudioEngineQueue(operationOwner) else { throw CancellationError() }
        recordInputSelection(snapshot.selectionApplication, operation: operation)

        guard snapshot.selectionApplication?.didApplyOverride == true else {
            return snapshot
        }

        let immediateReadiness = audioFormatReadiness(
            outputFormat: snapshot.outputFormat,
            hwFormat: snapshot.hwFormat,
            selection: snapshot.selection
        )
        let overrideSettleDelay = ParakeetInputOverrideSettlePolicy.delayNanoseconds(
            afterImmediateReadiness: immediateReadiness
        )
        if overrideSettleDelay == 0 {
            return snapshot
        }

        let settleSleepStartedAt = CFAbsoluteTimeGetCurrent()
        try? await Task.sleep(nanoseconds: overrideSettleDelay)
        stageTimings["audio_input_override_settle_sleep_ms"] = Self.elapsedMilliseconds(since: settleSleepStartedAt)
        guard ownsAudioEngineQueue(operationOwner) else { throw CancellationError() }
        if let recoveryGeneration, recoveryState.isStale(generation: recoveryGeneration) {
            throw CancellationError()
        }

        let settledSnapshotStartedAt = CFAbsoluteTimeGetCurrent()
        let settledSnapshotResult = try await runTimedAudioEngineWork(
            operation: "\(operation)_settled_snapshot",
            isWorkCurrent: isEngineWorkCurrent
        ) { audioEngine in
            let inputNode = audioEngine.inputNode
            return (
                outputFormat: Self.audioFormatSummary(inputNode.outputFormat(forBus: 0)),
                hwFormat: Self.audioFormatSummary(inputNode.inputFormat(forBus: 0)),
                engineWasRunning: audioEngine.isRunning
            )
        }
        stageTimings["audio_input_settled_snapshot_read_ms"] = Self.elapsedMilliseconds(since: settledSnapshotStartedAt)
        stageTimings["audio_input_total_ms"] = Self.elapsedMilliseconds(since: snapshotStartedAt)
        let settledSnapshot = ParakeetAudioInputSnapshot(
            outputFormat: settledSnapshotResult.outputFormat,
            hwFormat: settledSnapshotResult.hwFormat,
            selection: selection,
            selectionApplication: snapshot.selectionApplication,
            engineWasRunning: settledSnapshotResult.engineWasRunning,
            stageTimings: stageTimings
        )
        guard ownsAudioEngineQueue(operationOwner) else { throw CancellationError() }
        if let recoveryGeneration, recoveryState.isStale(generation: recoveryGeneration) {
            throw CancellationError()
        }
        let readiness = audioFormatReadiness(
            outputFormat: settledSnapshot.outputFormat,
            hwFormat: settledSnapshot.hwFormat,
            selection: settledSnapshot.selection
        )
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "dictation_input_device_override_settled",
            message: "Dictation input override settled before reading microphone format",
            context: audioFormatContext(
                outputFormat: settledSnapshot.outputFormat,
                hwFormat: settledSnapshot.hwFormat,
                selection: settledSnapshot.selection,
                readiness: readiness
            ).merging(
                ["operation": operation],
                uniquingKeysWith: { current, _ in current }
            )
        )
        return settledSnapshot
    }

    private func installTapAndStartEngine(
        startLeaseOwner: ParakeetAudioEngineQueueOwnerToken,
        startCancellationState: ParakeetAudioStartCancellationState
    ) async throws -> ParakeetAudioStartSnapshot {
        let wasPrewarmed = isEnginePrewarmed
        let workOwnership = audioEngineWorkOwnership
        let startWorkIsCurrent: () -> Bool = { [workOwnership] in
            startCancellationState.canRunWork
                && workOwnership.isActive(
                    owner: startLeaseOwner,
                    phase: .audioStart
                )
        }
        return try await runTimedAudioEngineWork(
            operation: "start_recording",
            isWorkCurrent: startWorkIsCurrent,
            cleanupAfterCancellation: Self.cleanUpLateAudioStart(on:),
            cleanupAfterLateCompletion: Self.cleanUpLateAudioStart(on:)
        ) { audioEngine in
            guard startWorkIsCurrent() else { throw CancellationError() }
            let workStartedAt = CFAbsoluteTimeGetCurrent()
            var stageTimings: [String: Int] = [:]
            let inputNode = audioEngine.inputNode
            let tapRemoveStartedAt = CFAbsoluteTimeGetCurrent()
            inputNode.removeTap(onBus: 0)
            stageTimings["audio_tap_remove_ms"] = Self.elapsedMilliseconds(since: tapRemoveStartedAt)
            let voiceProcessingRequested = MicrophoneProcessingPreferences.isVoiceProcessingEnabled()
            let voiceProcessingStartedAt = CFAbsoluteTimeGetCurrent()
            Self.applyDictationVoiceProcessingPreference(voiceProcessingRequested, to: inputNode)
            stageTimings["audio_voice_processing_apply_ms"] = Self.elapsedMilliseconds(since: voiceProcessingStartedAt)
            let tapInstallStartedAt = CFAbsoluteTimeGetCurrent()
            inputNode.installTap(onBus: 0, bufferSize: TranscriptedConstants.audioTapBufferSize, format: nil) { [weak self] buffer, _ in
                guard startCancellationState.canDeliverSamples else { return }
                guard let self = self,
                      let monoSamples = self.extractMonoSamples(from: buffer) else { return }
                let frameLength = monoSamples.count
                guard frameLength > 0 else { return }
                let bufferFormat = Self.audioFormatSummary(buffer.format)
                let effectiveSampleRate = ParakeetTapSampleRatePolicy.effectiveSampleRate(
                    bufferSampleRate: bufferFormat.sampleRate
                )
                self.nativeSampleRate = effectiveSampleRate
                let hasNonZeroSignal = ParakeetSampleSignalPolicy.hasNonZeroSignal(monoSamples)
                if hasNonZeroSignal {
                    self.didReceiveNonZeroAudioSamples = true
                }

                if !self.didReceiveAudioSamples && frameLength > 0 {
                    self.didReceiveAudioSamples = true
                    let startToFirstSampleMs = self.audioStartReferenceTime.map {
                        Int((CFAbsoluteTimeGetCurrent() - $0) * 1000)
                    }
                    Task { @MainActor in
                        var context = [
                            "sample_rate": "\(effectiveSampleRate)",
                            "channels": "\(bufferFormat.channelCount)",
                            "frames": "\(frameLength)",
                            "sample_signal_started": "\(hasNonZeroSignal)"
                        ]
                        if let startToFirstSampleMs {
                            context["start_to_first_sample_ms"] = "\(startToFirstSampleMs)"
                        }
                        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "audio_samples_detected",
                            message: "Audio samples started flowing",
                            context: context)
                    }
                }

                let truncatedSamples: Int = self.pendingSamplesLock.withLock {
                    self.pendingSamples.append(contentsOf: monoSamples)
                    let maxSamples = ParakeetAudioFormatReadinessPolicy.bufferCapacitySampleCount(
                        sampleRate: effectiveSampleRate,
                        seconds: TranscriptedConstants.audioBufferCapacitySeconds
                    )
                    let overflowMargin = Int(effectiveSampleRate)
                    guard self.pendingSamples.count > maxSamples + overflowMargin else { return 0 }
                    let dropped = self.pendingSamples.count - maxSamples
                    self.pendingSamples.removeFirst(dropped)
                    guard !self.didReportPendingSampleTruncation else { return 0 }
                    self.didReportPendingSampleTruncation = true
                    return dropped
                }
                if truncatedSamples > 0 {
                    let droppedSeconds = Double(truncatedSamples) / effectiveSampleRate
                    Task { @MainActor in
                        EventReporter.shared.capture(
                            level: .warning,
                            engine: "parakeet",
                            event: "audio_buffer_truncated",
                            message: "Recording exceeded the audio buffer capacity; oldest audio was dropped",
                            context: [
                                "dropped_seconds": String(format: "%.1f", droppedSeconds),
                                "capacity_seconds": "\(Int(TranscriptedConstants.audioBufferCapacitySeconds))",
                            ]
                        )
                    }
                }

                let now = CFAbsoluteTimeGetCurrent()
                guard now - self.lastLevelUpdate > TranscriptedConstants.audioMeteringInterval else { return }
                self.lastLevelUpdate = now

                let normalized = DictationAudioLevelMeter.normalizedLevel(from: buffer)

                Task { @MainActor [weak self] in
                    self?.audioLevel = normalized
                }
            }
            guard startWorkIsCurrent() else { throw CancellationError() }
            stageTimings["audio_tap_install_ms"] = Self.elapsedMilliseconds(since: tapInstallStartedAt)

            let engineWasRunning = audioEngine.isRunning
            if !wasPrewarmed || !audioEngine.isRunning {
                stageTimings["audio_engine_prepare_ms"] = 0
                let engineStartStartedAt = CFAbsoluteTimeGetCurrent()
                guard startWorkIsCurrent() else { throw CancellationError() }
                try audioEngine.start()
                guard startWorkIsCurrent() else { throw CancellationError() }
                stageTimings["audio_engine_start_ms"] = Self.elapsedMilliseconds(since: engineStartStartedAt)
            } else {
                stageTimings["audio_engine_prepare_ms"] = 0
                stageTimings["audio_engine_start_ms"] = 0
            }
            stageTimings["audio_start_work_ms"] = Self.elapsedMilliseconds(since: workStartedAt)
            return ParakeetAudioStartSnapshot(
                engineWasRunning: engineWasRunning,
                stageTimings: stageTimings
            )
        }
    }

    func removeRecordingTap(force: Bool = false) async {
        guard force || inputTapInstalled else { return }
        let tapOwner = currentAudioGraphOwnerToken()
        await runAudioEngineWork { audioEngine in
            // Stop + drain before removing the tap; the canonical stop path
            // (`removeRecordingTap()` then `stopAudioEngine()`) otherwise removes
            // the tap while the engine is still recording and can crash the
            // audio IO thread with `isSink || tap != nullptr`.
            Self.safelyRemoveInputTap(on: audioEngine)
        }
        guard ownsAudioGraph(tapOwner) else { return }
        inputTapInstalled = false
    }

    /// Share the user-consented issue #500 VPIO path with dictation. Meeting
    /// capture owns the prompt; dictation just honors the stable mic-processing
    /// preference on each new recording start.
    private nonisolated static func applyDictationVoiceProcessingPreference(
        _ enabled: Bool,
        to inputNode: AVAudioInputNode
    ) {
        guard inputNode.isVoiceProcessingEnabled != enabled else { return }
        do {
            try inputNode.setVoiceProcessingEnabled(enabled)
            if enabled {
                inputNode.isVoiceProcessingAGCEnabled = true
                if #available(macOS 14.0, *) {
                    inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false,
                        duckingLevel: .min
                    )
                }
            }
        } catch {
            let action = enabled ? "enable" : "disable"
            Task { @MainActor in
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "dictation_voice_processing_unavailable",
                    message: "Could not \(action) dictation voice processing; continuing with current input node mode",
                    context: ["requested": "\(enabled)"]
                )
            }
        }
    }

    func stopAudioEngine() async {
        await runAudioEngineWork { audioEngine in
            if audioEngine.isRunning {
                audioEngine.stop()
            }
        }
    }

    private func resetAudioGraphAfterStartFailure(
        reason: String,
        rebuildEngine: Bool
    ) async -> ParakeetAudioGraphOwnerToken? {
        // Keep runtime/UI state coherent when startRecording fails before we ever
        // transition to a stable recording session.
        cancelAudioWatchdogForRecordingStart()
        isRecording = false
        audioLevel = 0
        didReceiveAudioSamples = false
        didReceiveNonZeroAudioSamples = false
        recordingStartedOnLikelyBluetoothHandsFreeRoute = false

        // Reset/rebuild can block in CoreAudio too. Keep the admitted start's
        // exact resources claimable so a user stop can replace this queue
        // immediately instead of making the successor wait on stale cleanup.
        let resetWorkOwner = currentAudioEngineQueueOwnerToken()
        audioEngineWorkOwnership.begin(owner: resetWorkOwner, phase: .audioStart)
        defer {
            audioEngineWorkOwnership.finish(owner: resetWorkOwner, phase: .audioStart)
        }

        if rebuildEngine {
            return await rebuildAudioEngine(reason: reason)
        }
        audioGraphGeneration += 1
        let resetOwner = currentAudioGraphOwnerToken()
        await runAudioEngineWork { audioEngine in
            Self.safelyRemoveInputTap(on: audioEngine)
            audioEngine.reset()
        }
        guard ownsAudioGraph(resetOwner) else { return nil }
        inputTapInstalled = false
        isEnginePrewarmed = false
        return resetOwner
    }

    /// Tracks rebuild frequency and reports once if rebuilds are churning —
    /// a guardrail against a route-settling loop silently re-knocking Bluetooth
    /// audio instead of surfacing as a diagnosable failure.
    private func trackAudioEngineRebuildChurn(reason: String) {
        let now = CFAbsoluteTimeGetCurrent()
        recentAudioEngineRebuildTimestamps.append(now)
        let windowStart = now - TranscriptedConstants.audioEngineRebuildChurnWindow
        recentAudioEngineRebuildTimestamps.removeAll { $0 < windowStart }

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
    func rebuildAudioEngine(reason: String) async -> ParakeetAudioGraphOwnerToken? {
        trackAudioEngineRebuildChurn(reason: reason)
        audioGraphGeneration += 1
        let rebuildOwner = currentAudioGraphOwnerToken()
        removeAudioEngineConfigObserver()
        defer {
            restoreAudioEngineConfigObserverIfCurrent(rebuildOwner)
        }
        let retiredEngine = audioEngine
        await runAudioEngineWork { audioEngine in
            Self.safelyRemoveInputTap(on: audioEngine)
            audioEngine.reset()
        }
        guard ownsAudioGraph(rebuildOwner) else { return nil }
        // A stale overlapping rebuild may have restored an observer for the
        // engine being retired. Clear it before binding the replacement.
        removeAudioEngineConfigObserver()
        audioEngine = AVAudioEngine()
        ParakeetRetiredAudioEngineStore.shared.retire(retiredEngine, reason: reason)
        inputTapInstalled = false
        isEnginePrewarmed = false
        didReceiveAudioSamples = false
        didReceiveNonZeroAudioSamples = false
        recordingStartedOnLikelyBluetoothHandsFreeRoute = false
        if !isShuttingDown {
            installAudioEngineConfigObserverIfNeeded()
        }
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
        return currentAudioGraphOwnerToken()
    }

    @discardableResult
    func abandonBlockedAudioEngine(
        reason: String,
        expectedOwner: ParakeetAudioEngineQueueOwnerToken? = nil
    ) -> Bool {
        if let expectedOwner, !ownsAudioEngineQueue(expectedOwner) {
            return false
        }
        trackAudioEngineRebuildChurn(reason: reason)
        _ = audioEngineWorkOwnership.claimPendingWorkForSuccessor(
            currentEngine: audioEngine,
            currentQueue: audioEngineQueue
        )
        audioGraphGeneration += 1
        removeAudioEngineConfigObserver()
        let retiredEngine = audioEngine
        let retiredQueue = audioEngineQueue
        audioEngine = AVAudioEngine()
        audioEngineQueue = Self.makeAudioEngineQueue()
        ParakeetRetiredAudioEngineStore.shared.retire(retiredEngine, reason: reason)
        retiredQueue.async {
            Self.cleanUpLateAudioStart(on: retiredEngine)
        }
        inputTapInstalled = false
        isEnginePrewarmed = false
        didReceiveAudioSamples = false
        didReceiveNonZeroAudioSamples = false
        recordingStartedOnLikelyBluetoothHandsFreeRoute = false
        if !isShuttingDown {
            installAudioEngineConfigObserverIfNeeded()
        }
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
        return true
    }

    private func handleSystemWake() async {
        AppLogger.transcription.info("PARAKEET | system wake detected, resetting audio engine")
        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "system_wake",
            message: "System woke from sleep, resetting audio engine",
            context: ["was_recording": "\(isRecording)", "was_prewarmed": "\(isEnginePrewarmed)"])

        audioGraphGeneration += 1
        let wasRecording = isRecording
        cancelAudioWatchdog()
        audioStartAdmission.cancel()
        let wakeCleanupOwner = currentAudioEngineQueueOwnerToken()
        if isRecording {
            preserveCurrentRecordingBuffersForRecovery()
            await removeRecordingTap()
            guard ownsAudioEngineQueue(wakeCleanupOwner) else { return }
            isRecording = false
            audioLevel = 0
        }

        await stopAudioEngine()
        guard ownsAudioEngineQueue(wakeCleanupOwner) else { return }
        isEnginePrewarmed = false

        if wasRecording {
            interruptRecordingPreservingRecoveredTimeline()
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "recording_interrupted",
                message: "Recording interrupted by system sleep/wake")
        }
    }

    // MARK: - Recording

    @discardableResult
    private static func applyPreferredDictationInputDevice(
        _ selection: DictationInputDeviceSelection?,
        to inputNode: AVAudioInputNode
    ) -> ParakeetInputDeviceApplication? {
        guard let selection else {
            return nil
        }

        guard selection.didOverrideDefault else {
            return ParakeetInputDeviceApplication(
                selection: selection,
                didApplyOverride: false,
                reportKey: nil,
                errorDescription: nil
            )
        }

        guard inputNode.auAudioUnit.deviceID != selection.selectedInput.id else {
            return ParakeetInputDeviceApplication(
                selection: selection,
                didApplyOverride: false,
                reportKey: nil,
                errorDescription: nil
            )
        }

        do {
            try inputNode.auAudioUnit.setDeviceID(selection.selectedInput.id)
            return ParakeetInputDeviceApplication(
                selection: selection,
                didApplyOverride: true,
                reportKey: "\(selection.defaultInput.id)->\(selection.selectedInput.id)",
                errorDescription: nil
            )
        } catch {
            return ParakeetInputDeviceApplication(
                selection: selection,
                didApplyOverride: false,
                reportKey: nil,
                errorDescription: error.localizedDescription
            )
        }
    }

    private func recordInputSelection(
        _ application: ParakeetInputDeviceApplication?,
        operation: String
    ) {
        guard let application else { return }
        let selection = application.selection
        // Keep the analytics cache fresh from the selection just applied. When
        // the override failed the cache is slightly optimistic about the
        // selected input; analytics tolerates that, and the failure event
        // below records the truth.
        cachedInputDeviceSelection = selection

        guard selection.didOverrideDefault else {
            cachedInputDeviceName = selection.selectedInput.name
            lastInputSelectionReportKey = nil
            return
        }

        if let errorDescription = application.errorDescription {
            ignoreInputSelectionConfigChangesUntil = 0
            cachedInputDeviceName = selection.defaultInput.name
            var context = inputSelectionContext(selection, operation: operation)
            context["error"] = errorDescription
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "dictation_input_device_selection_failed",
                message: "Failed to apply preferred dictation input device",
                context: context
            )
            return
        }

        cachedInputDeviceName = selection.selectedInput.name
        guard application.didApplyOverride,
              let reportKey = application.reportKey,
              lastInputSelectionReportKey != reportKey else { return }

        lastInputSelectionReportKey = reportKey
        AppLogger.transcription.info("PARAKEET | using \(selection.selectedInput.name) instead of \(selection.defaultInput.name) to avoid Bluetooth headset mode")
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "dictation_input_device_auto_selected",
            message: "Dictation input changed away from Bluetooth headset microphone",
            context: inputSelectionContext(selection, operation: operation)
        )
    }

    func inputSelectionContext(
        _ selection: DictationInputDeviceSelection,
        operation: String? = nil
    ) -> [String: String] {
        var context = [
            "audio_device": selection.selectedInput.name,
            "default_input_device": selection.defaultInput.name,
            "selected_input_device": selection.selectedInput.name,
            "default_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput),
            "selected_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput),
            "selection_reason": selection.reason.rawValue,
            "selection_overrode_default": "\(selection.didOverrideDefault)"
        ]

        if let defaultOutput = selection.defaultOutput {
            context["default_output_device"] = defaultOutput.name
            context["default_output_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: defaultOutput)
        }

        if let operation {
            context["operation"] = operation
        }

        return context
    }

    private func audioStartContext(
        attempt: Int,
        isRecoveryAttempt: Bool,
        engineWasRunning: Bool,
        outputFormat: ParakeetAudioFormatSummary,
        hwFormat: ParakeetAudioFormatSummary,
        error: Error? = nil
    ) -> [String: String] {
        var context = [
            "attempt": "\(attempt)",
            "start_mode": isRecoveryAttempt ? "recovery" : "normal",
            "recovering": "\(recoveryState.isRecovering)",
            "format_ready": "\(recoveryState.inputFormatReady)",
            "generation": "\(recoveryState.generation)",
            "prewarmed": "\(isEnginePrewarmed)",
            "engine_running_before_start": "\(engineWasRunning)",
            "tap_installed": "\(inputTapInstalled)",
            "output_rate_hz": String(format: "%.0f", outputFormat.sampleRate),
            "output_channels": "\(outputFormat.channelCount)",
            "input_rate_hz": String(format: "%.0f", hwFormat.sampleRate),
            "hw_channels": "\(hwFormat.channelCount)",
            "input_device_class": inputDeviceClass(for: inputDeviceName),
        ]

        if let error {
            let nsError = error as NSError
            context["status_domain"] = nsError.domain
            context["status_code"] = "\(nsError.code)"
        }

        return context
    }

    private func inputDeviceClass(for deviceName: String) -> String {
        DictationInputDeviceSelectionPolicy.deviceClass(forName: deviceName)
    }

    private func reportAudioStartFailureIfNeeded(message: String, context: [String: String]) {
        let now = CFAbsoluteTimeGetCurrent()
        guard ParakeetAudioStartRecoveryPolicy.shouldReportFailure(
            now: now,
            lastReportAt: lastAudioStartFailureReportAt
        ) else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_engine_start_failed",
                message: message,
                context: context.merging(["report_throttled": "true"]) { current, _ in current }
            )
            return
        }

        lastAudioStartFailureReportAt = now
        EventReporter.shared.capture(
            level: .error,
            engine: "parakeet",
            event: "audio_engine_start_failed",
            message: message,
            context: context
        )
    }

    func startRecording(isRecoveryAttempt: Bool = false) async -> Bool {
        guard !isShuttingDown, !Task.isCancelled else { return false }
        guard !isRecording else { return true }
        guard !audioStartInProgress else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_start_deferred",
                message: "Audio start requested while another start is still in progress",
                context: [
                    "recovering": "\(recoveryState.isRecovering)",
                    "format_ready": "\(recoveryState.inputFormatReady)",
                    "generation": "\(recoveryState.generation)",
                    "audio_graph_generation": "\(audioGraphGeneration)"
                ]
            )
            return false
        }
        audioStartReferenceTime = CFAbsoluteTimeGetCurrent()
        audioGraphGeneration += 1
        var startOwner = currentAudioEngineQueueOwnerToken()
        guard audioStartAdmission.begin(owner: startOwner) else { return false }
        var startEngine = audioEngine
        var startQueue = audioEngineQueue
        defer {
            audioStartAdmission.finish(owner: startOwner)
        }
        func failAudioStart() async -> Bool {
            // Keep the temporary built-in input selected across the controller's
            // bounded retry loop. The final failure reset, explicit cancel,
            // cleanup, or a successful recording stop owns restoration.
            return false
        }

        scheduleInputDeviceNameRefresh()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "mic_not_authorized",
                message: "Microphone permission status: \(micStatus.rawValue)")
            return await failAudioStart()
        }

        installAudioObserversIfNeeded()
        guard isRecoveryAttempt || recoveryState.canStartRecording else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_start_deferred",
                message: "Audio start requested while input format is still recovering",
                context: [
                    "recovering": "\(recoveryState.isRecovering)",
                    "format_ready": "\(recoveryState.inputFormatReady)",
                    "generation": "\(recoveryState.generation)"
                ]
            )
            if !recoveryState.isRecovering {
                schedulePrewarmRetry()
            }
            return await failAudioStart()
        }

        recordingInterrupted = false
        didReceiveAudioSamples = false
        didReceiveNonZeroAudioSamples = false
        recordingStartedOnLikelyBluetoothHandsFreeRoute = false
        cancelAudioWatchdogForRecordingStart()
        if !isRecoveryAttempt && !preservingRecordingAcrossRecovery {
            recoveredRecordingTimeline.removeAll(keepingCapacity: true)
        }
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
            didReportPendingSampleTruncation = false
        }
        sampleBuffer.removeAll(keepingCapacity: true)
        reserveNativeSampleBufferCapacity()

        let maxAttempts = isRecoveryAttempt ? 1 : 1 + TranscriptedConstants.audioStartRecoveryAttempts
        for attempt in 1...maxAttempts {
            let attemptOwner = startOwner
            let attemptEngine = startEngine
            let attemptQueue = startQueue
            guard ownsAudioEngineQueue(attemptOwner) else {
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "audio_start_aborted",
                    message: "Audio start aborted because the audio graph changed before startup finished",
                    context: ["audio_graph_generation": "\(audioGraphGeneration)"]
                )
                return await failAudioStart()
            }

            // The format reads below use the same serial engine queue as tap
            // installation. Lease them before the first suspension so stop can
            // retire a blocked snapshot instead of stranding the next start.
            let snapshotCancellationState = ParakeetAudioStartCancellationState()
            audioStartCancellationState?.cancel()
            audioStartCancellationState = snapshotCancellationState
            audioEngineWorkOwnership.begin(owner: attemptOwner, phase: .audioStart)
            let snapshotWorkIsCurrent: () -> Bool = { [audioEngineWorkOwnership] in
                snapshotCancellationState.canRunWork
                    && audioEngineWorkOwnership.isActive(owner: attemptOwner, phase: .audioStart)
            }
            func finishSnapshotLease() {
                snapshotCancellationState.cancel()
                audioEngineWorkOwnership.finish(owner: attemptOwner, phase: .audioStart)
                if audioStartCancellationState === snapshotCancellationState {
                    audioStartCancellationState = nil
                }
            }

            let snapshot: ParakeetAudioInputSnapshot
            do {
                snapshot = try await audioInputSnapshot(
                    operation: "start_recording",
                    allowsBuiltInBluetoothFallback: !isRecoveryAttempt,
                    isEngineWorkCurrent: snapshotWorkIsCurrent
                )
                finishSnapshotLease()
            } catch {
                finishSnapshotLease()
                guard ownsAudioEngineQueue(attemptOwner) else { return await failAudioStart() }
                let audioEngineTimedOut = error is ParakeetAudioEngineWorkError
                let operationTimedOut = audioEngineTimedOut
                    || error is ParakeetSystemInputWorkError
                EventReporter.shared.capture(
                    level: operationTimedOut ? .error : .warning,
                    engine: "parakeet",
                    event: operationTimedOut ? "audio_format_read_timeout" : "audio_format_unavailable",
                    message: operationTimedOut
                        ? "Audio hardware format read timed out while starting dictation"
                        : "Audio hardware format could not be read while starting dictation",
                    context: [
                        "attempt": "\(attempt)",
                        "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                        "error": error.localizedDescription
                    ]
                )
                if audioEngineTimedOut {
                    guard abandonBlockedAudioEngine(
                        reason: "audio_format_read_timeout",
                        expectedOwner: attemptOwner
                    ) else { return await failAudioStart() }
                } else {
                    guard await resetAudioGraphAfterStartFailure(
                        reason: "audio_format_read_failed",
                        rebuildEngine: true
                    ) != nil else { return await failAudioStart() }
                }
                markFormatUnreadyAndPublish()
                schedulePrewarmRetry()
                return await failAudioStart()
            }
            guard ownsAudioEngineQueue(attemptOwner) else {
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "audio_start_aborted",
                    message: "Audio start aborted because the audio graph changed while reading input format",
                    context: ["audio_graph_generation": "\(audioGraphGeneration)"]
                )
                return await failAudioStart()
            }

            let readiness = audioFormatReadiness(
                outputFormat: snapshot.outputFormat,
                hwFormat: snapshot.hwFormat,
                selection: snapshot.selection
            )
            guard readiness == .ready else {
                let startFailureAction = ParakeetStartRecordingFailurePolicy.action(
                    for: readiness.startFailureReason ?? .invalidAudioFormat,
                    isRecoveryAttempt: isRecoveryAttempt
                )
                AppLogger.transcription.warning("PARAKEET | input format unavailable (\(readiness.rawValue)): output=\(snapshot.outputFormat.sampleRate)Hz/\(snapshot.outputFormat.channelCount)ch hw=\(snapshot.hwFormat.sampleRate)Hz/\(snapshot.hwFormat.channelCount)ch")
                var context = audioStartContext(
                    attempt: attempt,
                    isRecoveryAttempt: isRecoveryAttempt,
                    engineWasRunning: snapshot.engineWasRunning,
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat
                )
                context.merge(
                    audioFormatContext(
                        outputFormat: snapshot.outputFormat,
                        hwFormat: snapshot.hwFormat,
                        selection: snapshot.selection,
                        readiness: readiness
                    )
                ) { current, _ in current }
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "audio_format_unavailable",
                    message: "Audio hardware format not ready while starting dictation",
                    context: context
                )
                guard await resetAudioGraphAfterStartFailure(
                    reason: readiness == .routeNotSettled ? "audio_route_not_settled" : "invalid_audio_format",
                    rebuildEngine: startFailureAction.rebuildAudioEngine
                ) != nil else { return await failAudioStart() }
                if startFailureAction.markFormatUnready {
                    markFormatUnreadyAndPublish()
                }
                if startFailureAction.schedulePrewarmRetry {
                    schedulePrewarmRetry()
                }
                return await failAudioStart()
            }

            updateNativeSampleRate(snapshot.outputFormat.sampleRate)
            recordingStartedOnLikelyBluetoothHandsFreeRoute = ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(
                inputClass: selectedInputClass(for: snapshot.selection),
                outputDeviceClass: defaultOutputClass(for: snapshot.selection),
                inputRate: snapshot.hwFormat.sampleRate,
                outputRate: snapshot.outputFormat.sampleRate
            )
            reserveNativeSampleBufferCapacity()

            if let generation = zombieRecoveryStartGeneration {
                guard zombieRecoveryState.canContinue(generation: generation) else {
                    return await failAudioStart()
                }
            }
            let startCancellationState = ParakeetAudioStartCancellationState()
            audioStartCancellationState?.cancel()
            audioStartCancellationState = startCancellationState
            audioEngineWorkOwnership.begin(owner: attemptOwner, phase: .audioStart)

            do {
                let startSnapshot = try await installTapAndStartEngine(
                    startLeaseOwner: attemptOwner,
                    startCancellationState: startCancellationState
                )
                guard ownsAudioEngineQueue(attemptOwner) else {
                    startCancellationState.cancel()
                    audioEngineWorkOwnership.finish(owner: attemptOwner, phase: .audioStart)
                    if audioStartCancellationState === startCancellationState {
                        audioStartCancellationState = nil
                    }
                    attemptQueue.async {
                        Self.cleanUpLateAudioStart(on: attemptEngine)
                    }
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "audio_start_aborted",
                        message: "Audio start aborted because the audio graph changed while starting",
                        context: ["audio_graph_generation": "\(audioGraphGeneration)"]
                    )
                    return await failAudioStart()
                }
                if !startCancellationState.commit() {
                    audioEngineWorkOwnership.finish(owner: attemptOwner, phase: .audioStart)
                    if audioStartCancellationState === startCancellationState {
                        audioStartCancellationState = nil
                    }
                    attemptQueue.async {
                        Self.cleanUpLateAudioStart(on: attemptEngine)
                    }
                    return await failAudioStart()
                }
                audioEngineWorkOwnership.finish(owner: attemptOwner, phase: .audioStart)
                inputTapInstalled = true
                isEnginePrewarmed = true

                var timingContext = dictationRouteAnalyticsContext(
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat,
                    selection: snapshot.selection,
                    extra: [
                        "engine_running_before_start": "\(startSnapshot.engineWasRunning)",
                        "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                    ]
                )
                timingContext.merge(Self.timingContext(snapshot.stageTimings)) { current, _ in current }
                timingContext.merge(Self.timingContext(startSnapshot.stageTimings)) { current, _ in current }
                EventReporter.shared.capture(
                    level: .info,
                    engine: "parakeet",
                    event: "dictation_audio_start_timing",
                    message: "Dictation audio start stage timing",
                    context: timingContext
                )

                if !startSnapshot.engineWasRunning && isEnginePrewarmed {
                    EventReporter.shared.capture(level: .info, engine: "parakeet",
                        event: "audio_engine_started",
                        message: "Audio engine started on worker queue",
                        context: [
                            "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                            "output_rate_hz": String(format: "%.0f", snapshot.outputFormat.sampleRate),
                            "input_rate_hz": String(format: "%.0f", snapshot.hwFormat.sampleRate)
                        ])
                }
            } catch {
                startCancellationState.cancel()
                if audioStartCancellationState === startCancellationState {
                    audioStartCancellationState = nil
                }
                audioEngineWorkOwnership.finish(owner: attemptOwner, phase: .audioStart)
                guard ownsAudioEngineQueue(attemptOwner) else { return await failAudioStart() }
                let operationTimedOut = error is ParakeetAudioEngineWorkError
                var context = audioStartContext(
                    attempt: attempt,
                    isRecoveryAttempt: isRecoveryAttempt,
                    engineWasRunning: snapshot.engineWasRunning,
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat,
                    error: error
                )
                let failureReason = operationTimedOut
                    ? ParakeetStartRecordingFailureReason.audioEngineStartTimedOut
                    : ParakeetAudioFormatReadinessPolicy.startFailureReason(for: error as NSError)
                let startFailureAction = ParakeetStartRecordingFailurePolicy.action(
                    for: failureReason,
                    isRecoveryAttempt: isRecoveryAttempt
                )
                context["failure_kind"] = operationTimedOut ? "audio_engine_start_timeout" : "audio_engine_start_failed"
                context["sample_flow_started"] = "\(didReceiveAudioSamples)"
                context["sample_signal_started"] = "\(didReceiveNonZeroAudioSamples)"
                let shouldRetry = !operationTimedOut
                    && failureReason == .audioEngineStartFailed
                    && ParakeetAudioStartRecoveryPolicy.shouldRetryStartFailure(
                    isRecoveryAttempt: isRecoveryAttempt,
                    failedAttempts: attempt
                )
                if operationTimedOut {
                    guard abandonBlockedAudioEngine(
                        reason: "audio_engine_start_timeout",
                        expectedOwner: attemptOwner
                    ) else { return await failAudioStart() }
                } else {
                    guard await resetAudioGraphAfterStartFailure(
                        reason: failureReason == .audioRouteNotSettled ? "audio_route_not_settled" : "audio_engine_start_failed",
                        rebuildEngine: startFailureAction.rebuildAudioEngine
                    ) != nil else { return await failAudioStart() }
                }

                if shouldRetry {
                    let retryOwner = currentAudioEngineQueueOwnerToken()
                    guard audioStartAdmission.transfer(from: startOwner, to: retryOwner) else {
                        return await failAudioStart()
                    }
                    startOwner = retryOwner
                    startEngine = audioEngine
                    startQueue = audioEngineQueue
                    AppLogger.transcription.warning("PARAKEET | audio engine start failed, resetting graph and retrying once: \(error.localizedDescription)")
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "audio_engine_start_retrying",
                        message: "Audio engine failed to start; resetting graph and retrying",
                        context: context
                    )
                    continue
                }

                if failureReason == .audioRouteNotSettled {
                    AppLogger.transcription.warning("PARAKEET | audio route format unsupported while starting; waiting for CoreAudio to settle")
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "audio_route_not_settled",
                        message: "Audio route format was not ready while starting dictation",
                        context: context
                    )
                    if startFailureAction.markFormatUnready {
                        markStartFailedAndPublish()
                    }
                    if startFailureAction.schedulePrewarmRetry {
                        schedulePrewarmRetry()
                    }
                    return await failAudioStart()
                }

                if operationTimedOut {
                    AppLogger.transcription.error("PARAKEET | audio engine start timed out after \(attempt) attempt(s): \(error.localizedDescription)")
                    EventReporter.shared.capture(
                        level: .error,
                        engine: "parakeet",
                        event: "audio_engine_start_timeout",
                        message: "Audio engine start timed out; abandoned blocked microphone graph",
                        context: context
                    )
                    if startFailureAction.markFormatUnready {
                        markStartFailedAndPublish()
                    }
                    if startFailureAction.schedulePrewarmRetry {
                        schedulePrewarmRetry()
                    }
                    return await failAudioStart()
                }

                AppLogger.transcription.error("PARAKEET | audio engine failed after \(attempt) attempt(s): \(error.localizedDescription)")
                reportAudioStartFailureIfNeeded(message: error.localizedDescription, context: context)
                if startFailureAction.markFormatUnready {
                    markStartFailedAndPublish()
                }
                if startFailureAction.schedulePrewarmRetry {
                    schedulePrewarmRetry()
                }
                return await failAudioStart()
            }

            if attempt > 1 {
                EventReporter.shared.capture(
                    level: .info,
                    engine: "parakeet",
                    event: "audio_engine_start_recovered",
                    message: "Audio engine started after a graph reset",
                    context: [
                        "attempts": "\(attempt)",
                        "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                        "output_rate_hz": String(format: "%.0f", snapshot.outputFormat.sampleRate),
                        "output_channels": "\(snapshot.outputFormat.channelCount)",
                        "input_rate_hz": String(format: "%.0f", snapshot.hwFormat.sampleRate),
                        "hw_channels": "\(snapshot.hwFormat.channelCount)",
                    ]
                )
            }
            lastAudioStartFailureReportAt = nil
            break
        }

        isRecording = true
        markFormatReadyAndPublish()
        AppLogger.transcription.info("PARAKEET | recording started (\(inputDeviceName), \(safeNativeSampleRate())Hz)")

        // Watchdog: detect zombie audio engine (running but no usable signal after sleep/wake).
        // Only on first attempt — recovery attempt doesn't re-watchdog to prevent infinite loops.
        if !isRecoveryAttempt {
            startAudioWatchdog()
        }

        return true
    }

    /// Begin dictation by borrowing the mic stream already owned by meeting
    /// capture. This deliberately does not touch AVAudioEngine or the system
    /// input route.
    func startSharedMeetingMicRecording() -> Bool {
        guard !isShuttingDown, !isRecording, !audioStartInProgress else { return false }

        cancelAudioWatchdog()
        recordingInterrupted = false
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        sampleBuffer.removeAll(keepingCapacity: true)
        clearRecoveredRecordingTimeline(keepingCapacity: true)
        sharedMeetingMicRecorder.begin()
        sharedMeetingMicTransition.beginSharedRecording()
        sharedMeetingMicRecording = true
        isRecording = true
        audioLevel = 0

        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "dictation_shared_meeting_mic_started",
            message: "Dictation started from the active meeting microphone stream"
        )
        return true
    }

    /// Called from MeetingCaptureBridge's off-tap relay queue.
    nonisolated func appendSharedMeetingMicBuffer(_ buffer: AVAudioPCMBuffer) {
        sharedMeetingMicRecorder.append(buffer)
    }

    func updateSharedMeetingMicAudioLevel(_ level: Float) {
        guard sharedMeetingMicRecording else { return }
        audioLevel = max(0, min(1, level))
    }

    /// If meeting capture ends first, preserve everything already borrowed and
    /// continue the same dictation on its regular mic engine.
    func resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded() async {
        guard sharedMeetingMicRecording else { return }
        let transitionToken = sharedMeetingMicTransition.beginResume()
        finishSharedMeetingMicRecording(keepRecordingState: false)
        preservingRecordingAcrossRecovery = !recoveredRecordingTimeline.isEmpty

        let started = await startRecording(isRecoveryAttempt: true)
        guard sharedMeetingMicTransition.finishResume(token: transitionToken) else {
            if started {
                let pendingRestoreOwner = pendingSystemInputRestore.owner
                audioGraphGeneration += 1
                cancelAudioWatchdog()
                let staleResumeOwner = currentAudioEngineQueueOwnerToken()
                await removeRecordingTap()
                guard ownsAudioEngineQueue(staleResumeOwner) else { return }
                await stopAudioEngine()
                guard ownsAudioEngineQueue(staleResumeOwner) else { return }
                isRecording = false
                audioLevel = 0
                await restorePendingSystemInputAfterRecording(
                    ownedBy: pendingRestoreOwner,
                    operation: "stale_shared_meeting_mic_resume"
                )
            }
            return
        }

        guard started else {
            interruptRecordingPreservingRecoveredTimeline()
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "dictation_shared_meeting_mic_resume_failed",
                message: "Dictation could not resume regular mic capture after the meeting ended"
            )
            return
        }

        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "dictation_shared_meeting_mic_resumed_regular_capture",
            message: "Dictation resumed regular mic capture after the meeting ended"
        )
    }

    private func finishSharedMeetingMicRecording(keepRecordingState: Bool) {
        sharedMeetingMicRecording = false
        var timeline = sharedMeetingMicRecorder.finish()
        for segment in timeline.drain() {
            recoveredRecordingTimeline.append(segment.samples, sampleRate: segment.sampleRate)
        }
        preservingRecordingAcrossRecovery = !recoveredRecordingTimeline.isEmpty
        isRecording = keepRecordingState
        audioLevel = 0
    }

    private func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        guard frameCount > 0, channelCount > 0 else { return [] }

        if channelCount == 1 {
            guard let channelData = buffer.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        }

        var monoSamples = Array<Float>(repeating: 0, count: frameCount)

        if buffer.format.isInterleaved {
            guard let interleavedData = buffer.floatChannelData?[0] else { return nil }
            for frame in 0..<frameCount {
                let baseIndex = frame * channelCount
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += interleavedData[baseIndex + channel]
                }
                monoSamples[frame] = sum / Float(channelCount)
            }
            return monoSamples
        }

        guard let channelData = buffer.floatChannelData else { return nil }
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channelData[channel][frame]
            }
            monoSamples[frame] = sum / Float(channelCount)
        }
        return monoSamples
    }

    /// Watchdog that detects zombie audio engines — running but producing no usable signal.
    /// After sleep/wake, CoreAudio may report the engine as running but the hardware graph
    /// is disconnected. If no samples arrive within 2 seconds, replace the stale engine
    /// through a bounded reset and retry once.
    /// If the user stops dictation during the recovery delay, the pending retry is cleared
    /// so the watchdog does not revive a recording the user already ended.
    private func startAudioWatchdog() {
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
        audioWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioWatchdogTimeout)
            guard let self = self, self.isRecording, !Task.isCancelled else { return }

            let sampleCount = self.pendingSamplesLock.withLock {
                guard self.isRecording else { return -1 }
                return self.pendingSamples.count + self.sampleBuffer.count
            }
            guard sampleCount >= 0 else { return }

            let shouldReset = ParakeetSampleSignalPolicy.shouldResetStartupAudio(
                sampleCount: sampleCount,
                hasNonZeroSignal: self.didReceiveNonZeroAudioSamples,
                isLikelyBluetoothHandsFreeRoute: self.recordingStartedOnLikelyBluetoothHandsFreeRoute
            )
            guard shouldReset else { return }

            let failureKind = sampleCount == 0 ? "no_sample_callbacks" : "silent_hfp_callbacks"
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "zombie_engine_detected",
                message: sampleCount == 0
                    ? "No audio samples received after recording start — resetting engine"
                    : "Only silent audio samples received after recording start — resetting engine",
                context: self.zombieRecoveryTelemetryContext(
                    failureKind: failureKind,
                    stage: .detected,
                    result: nil
                ))

            // Detection and recovery use separate task lifetimes. Otherwise the
            // recovery's call into startRecording cancels the watchdog task that
            // is currently executing, skipping cancellation-aware settle work.
            self.audioWatchdogTask = nil
            self.startZombieEngineRecovery(failureKind: failureKind)
        }
    }

    private func startZombieEngineRecovery(failureKind: String) {
        guard !zombieRecoveryState.isActive else { return }
        let generation = zombieRecoveryState.begin(failureKind: failureKind)
        zombieRecoveryTask = Task { @MainActor [weak self] in
            await self?.runZombieEngineRecovery(generation: generation)
        }
    }

    private func runZombieEngineRecovery(generation: UInt64) async {
        defer {
            clearZombieRecoveryStartGeneration(ifMatching: generation)
            if zombieRecoveryState.canContinue(generation: generation) {
                finishZombieEngineRecovery(
                    generation: generation,
                    result: Task.isCancelled ? .cancelled : .failed
                )
            }
        }

        guard zombieRecoveryState.advance(to: .reset, generation: generation) else { return }
        let recoveryGraphOwner = currentAudioGraphOwnerToken()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
            didReportPendingSampleTruncation = false
        }
        isRecording = false
        audioLevel = 0
        configChangeWasRecording = false
        ignoreInputSelectionConfigChangesUntil = CFAbsoluteTimeGetCurrent()
            + TranscriptedConstants.selfInducedConfigChangeIgnoreWindow

        // Stop/config-change cancellation takes ownership of graph cleanup. The
        // superseded zombie task must not enter recreation after this suspension.
        guard canContinueZombieEngineRecovery(
            generation: generation,
            expectedOwner: recoveryGraphOwner
        ) else { return }
        guard await recreateAudioEngineForZombieRecovery(
            generation: generation,
            expectedOwner: recoveryGraphOwner
        ) else { return }
        guard !Task.isCancelled, zombieRecoveryState.canContinue(generation: generation) else { return }

        guard zombieRecoveryState.advance(to: .settle, generation: generation) else { return }
        do {
            try await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
        } catch {
            return
        }
        guard !Task.isCancelled, zombieRecoveryState.canContinue(generation: generation) else { return }

        guard zombieRecoveryState.advance(to: .restart, generation: generation) else { return }
        zombieRecoveryStartGeneration = generation
        let started = await startRecording(isRecoveryAttempt: true)
        clearZombieRecoveryStartGeneration(ifMatching: generation)
        guard zombieRecoveryState.canContinue(generation: generation) else { return }

        if started {
            AppLogger.transcription.info("PARAKEET | zombie engine recovered — recording restarted")
            finishZombieEngineRecovery(generation: generation, result: .succeeded)
        } else {
            AppLogger.transcription.error("PARAKEET | zombie engine recovery failed")
            interruptRecordingPreservingRecoveredTimeline()
            finishZombieEngineRecovery(generation: generation, result: .failed)
        }
    }

    /// A detected zombie is evidence that the current AVAudioEngine graph is stale.
    /// Replace that instance rather than stopping and starting it again. Queue work
    /// is bounded; if CoreAudio does not return, abandon the old graph and queue.
    private func recreateAudioEngineForZombieRecovery(
        generation: UInt64,
        expectedOwner: ParakeetAudioGraphOwnerToken
    ) async -> Bool {
        guard canContinueZombieEngineRecovery(
            generation: generation,
            expectedOwner: expectedOwner
        ) else { return false }

        trackAudioEngineRebuildChurn(reason: "zombie_engine_recovery")
        audioGraphGeneration += 1
        let resetOwner = currentAudioGraphOwnerToken()
        let resetQueueOwner = currentAudioEngineQueueOwnerToken()
        removeAudioEngineConfigObserver()
        defer {
            restoreAudioEngineConfigObserverIfCurrent(resetOwner)
        }
        let retiredEngine = audioEngine
        audioEngineWorkOwnership.begin(owner: resetQueueOwner, phase: .zombieReset)

        do {
            try await runTimedAudioEngineWork(operation: "zombie_engine_reset") { [audioEngineWorkOwnership] audioEngine in
                defer {
                    audioEngineWorkOwnership.finish(
                        owner: resetQueueOwner,
                        phase: .zombieReset
                    )
                }
                Self.safelyRemoveInputTap(on: audioEngine)
                audioEngine.reset()
            }
        } catch {
            audioEngineWorkOwnership.finish(owner: resetQueueOwner, phase: .zombieReset)
            guard error is ParakeetAudioEngineWorkError else { return false }
            guard canContinueZombieEngineRecovery(
                generation: generation,
                expectedOwner: resetOwner
            ) else { return false }

            // Only the exact generation+engine owner may abandon a timed-out
            // queue; a newer graph may reuse the same engine instance.
            return abandonBlockedAudioEngine(
                reason: "zombie_engine_reset_timeout",
                expectedOwner: resetQueueOwner
            )
        }

        guard canContinueZombieEngineRecovery(
            generation: generation,
            expectedOwner: resetOwner
        ) else { return false }

        inputTapInstalled = false
        isEnginePrewarmed = false
        didReceiveAudioSamples = false
        didReceiveNonZeroAudioSamples = false
        recordingStartedOnLikelyBluetoothHandsFreeRoute = false
        removeAudioEngineConfigObserver()
        audioEngine = AVAudioEngine()
        ParakeetRetiredAudioEngineStore.shared.retire(retiredEngine, reason: "zombie_engine_recovery")
        if !isShuttingDown {
            installAudioEngineConfigObserverIfNeeded()
        }
        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "audio_engine_rebuilt",
            message: "Audio engine replaced after zombie-state detection",
            context: ["reason": "zombie_engine_recovery"]
        )
        return true
    }

    func currentAudioGraphOwnerToken() -> ParakeetAudioGraphOwnerToken {
        ParakeetAudioGraphOwnerToken(generation: audioGraphGeneration, engine: audioEngine)
    }

    func ownsAudioGraph(_ owner: ParakeetAudioGraphOwnerToken) -> Bool {
        owner.matches(generation: audioGraphGeneration, engine: audioEngine)
    }

    func currentAudioEngineQueueOwnerToken() -> ParakeetAudioEngineQueueOwnerToken {
        ParakeetAudioEngineQueueOwnerToken(
            generation: audioGraphGeneration,
            engine: audioEngine,
            queue: audioEngineQueue
        )
    }

    func ownsAudioEngineQueue(_ owner: ParakeetAudioEngineQueueOwnerToken) -> Bool {
        owner.matches(
            generation: audioGraphGeneration,
            engine: audioEngine,
            queue: audioEngineQueue
        )
    }

    private func canContinueZombieEngineRecovery(
        generation: UInt64,
        expectedOwner: ParakeetAudioGraphOwnerToken
    ) -> Bool {
        ParakeetZombieRecoveryOwnershipPolicy.canContinue(
            taskIsCancelled: Task.isCancelled,
            recoveryIsCurrent: zombieRecoveryState.canContinue(generation: generation),
            expectedOwner: expectedOwner,
            currentGraphGeneration: audioGraphGeneration,
            currentEngine: audioEngine
        )
    }

    private func clearZombieRecoveryStartGeneration(ifMatching generation: UInt64) {
        guard zombieRecoveryStartGeneration == generation else { return }
        zombieRecoveryStartGeneration = nil
    }

    private func finishZombieEngineRecovery(
        generation: UInt64,
        result: ParakeetZombieRecoveryResult
    ) {
        guard let terminal = zombieRecoveryState.finish(result: result, generation: generation) else { return }
        zombieRecoveryTask = nil
        reportZombieEngineRecoveryTerminal(terminal)
    }

    private func reportZombieEngineRecoveryTerminal(_ terminal: ParakeetZombieRecoveryTerminal) {
        let context = zombieRecoveryTelemetryContext(
            failureKind: terminal.failureKind,
            stage: terminal.stage,
            result: terminal.result
        )
        AnalyticsReporter.track("dictation_zombie_recovery_finished", properties: context)

        switch terminal.result {
        case .succeeded:
            EventReporter.shared.capture(
                level: .info,
                engine: "parakeet",
                event: "zombie_engine_recovered",
                message: "Audio engine recovered after bounded replacement",
                context: context
            )
        case .failed:
            EventReporter.shared.capture(
                level: .error,
                engine: "parakeet",
                event: "zombie_engine_recovery_failed",
                message: "Audio engine could not recover after bounded replacement",
                context: context
            )
        case .cancelled:
            EventReporter.shared.capture(
                level: .info,
                engine: "parakeet",
                event: "zombie_engine_recovery_cancelled",
                message: "Audio engine recovery was cancelled",
                context: context
            )
        }
    }

    private func zombieRecoveryTelemetryContext(
        failureKind: String,
        stage: ParakeetZombieRecoveryStage,
        result: ParakeetZombieRecoveryResult?
    ) -> [String: String] {
        let route = dictationRouteAnalyticsContext(selection: cachedInputDeviceSelection)
        var context: [String: String] = [
            "failure_kind": failureKind,
            "hfp_suspected": route["hfp_suspected"] ?? "false",
            "input_device_class": route["input_device_class"] ?? "unknown",
            "output_device_class": route["output_device_class"] ?? "unknown",
            "route_shape": route["route_shape"] ?? "unknown",
            "stage": stage.rawValue,
        ]
        if let result {
            context["result"] = result.rawValue
        }
        return context
    }

    func stopRecording() async {
        if sharedMeetingMicRecording || sharedMeetingMicTransition.isResumeInProgress {
            sharedMeetingMicTransition.invalidate()
        }
        if sharedMeetingMicRecording {
            finishSharedMeetingMicRecording(keepRecordingState: false)
            EventReporter.shared.capture(
                level: .info,
                engine: "parakeet",
                event: "dictation_shared_meeting_mic_stopped",
                message: "Dictation stopped borrowing the active meeting microphone stream"
            )
            return
        }

        guard !audioStopInProgress else { return }
        audioStopInProgress = true
        defer { audioStopInProgress = false }

        let configRecoveryGeneration = recoveryState.isRecovering
            ? recoveryState.generation
            : nil
        audioGraphGeneration += 1
        cancelAudioWatchdog()
        if let configRecoveryGeneration {
            cancelConfigRecoveryIfCurrent(generation: configRecoveryGeneration)
        }

        let pendingRestoreOwner = pendingSystemInputRestore.owner
        guard isRecording else {
            // Genuinely preserved/recovered audio (e.g. real pre-sleep audio held
            // across a wake-recovery gap) must win over a merely-pending zombie
            // restart — checking this first ensures a stop during an in-flight
            // zombie retry drains real audio instead of discarding it.
            if preservingRecordingAcrossRecovery || !recoveredRecordingTimeline.isEmpty {
                cancelPendingRecordingRecovery()
                await restorePendingSystemInputAfterRecording(
                    ownedBy: pendingRestoreOwner,
                    operation: "stop_recording_preserved_recovery"
                )
                return
            }
            // A zombie reset marks recording idle while it waits to retry, with
            // nothing preserved worth keeping. Treat a user stop in that window
            // as cancellation of the pending restart.
            if zombieRecoveryRestartPending {
                let stopGraphGeneration = audioGraphGeneration
                audioStartAdmission.cancel()
                clearRecoveredRecordingTimeline(keepingCapacity: true)
                await releaseIdleAudioHardware(
                    removeTap: true,
                    expectedGeneration: stopGraphGeneration
                )
                await restorePendingSystemInputAfterRecording(
                    ownedBy: pendingRestoreOwner,
                    operation: "stop_recording_zombie_restart"
                )
                return
            }
            if audioStartInProgress {
                // A normal start can be blocked inside CoreAudio just like a
                // zombie restart. Claim its exact timed-work lease and replace
                // both resources before allowing the next start to enqueue.
                audioStartAdmission.cancel()
            } else {
                clearRecoveredRecordingTimeline(keepingCapacity: true)
            }
            await restorePendingSystemInputAfterRecording(
                ownedBy: pendingRestoreOwner,
                operation: "stop_recording_idle"
            )
            return
        }
        let stopOwner = currentAudioEngineQueueOwnerToken()
        await removeRecordingTap()
        var stillOwnsStopGraph = ownsAudioEngineQueue(stopOwner)
        if stillOwnsStopGraph {
            await stopAudioEngine()
            stillOwnsStopGraph = ownsAudioEngineQueue(stopOwner)
        }
        await restorePendingSystemInputAfterRecording(
            ownedBy: pendingRestoreOwner,
            operation: "stop_recording"
        )
        guard stillOwnsStopGraph, ownsAudioEngineQueue(stopOwner) else { return }
        isEnginePrewarmed = false
        drainPendingSamplesIntoSampleBuffer()
        isRecording = false
        audioLevel = 0
        let stopSampleRate = safeNativeSampleRate()
        AppLogger.transcription.info("PARAKEET | recording stopped (\(sampleBuffer.count) samples, \(String(format: "%.1f", Double(sampleBuffer.count) / stopSampleRate))s)")
    }

    // MARK: - Recorded Audio Buffering

    private func drainPendingSamplesIntoSampleBuffer() {
        pendingSamplesLock.withLock {
            guard !pendingSamples.isEmpty else { return }
            if sampleBuffer.isEmpty {
                swap(&sampleBuffer, &pendingSamples)
            } else {
                sampleBuffer.append(contentsOf: pendingSamples)
                pendingSamples.removeAll(keepingCapacity: false)
            }
        }
    }

    func preserveCurrentRecordingBuffersForRecovery() {
        drainPendingSamplesIntoSampleBuffer()
        if !sampleBuffer.isEmpty {
            recoveredRecordingTimeline.append(sampleBuffer, sampleRate: safeNativeSampleRate())
            sampleBuffer.removeAll(keepingCapacity: true)
        }
        preservingRecordingAcrossRecovery = !recoveredRecordingTimeline.isEmpty
    }

    private func clearRecoveredRecordingTimeline(keepingCapacity: Bool = true) {
        recoveredRecordingTimeline.removeAll(keepingCapacity: keepingCapacity)
        preservingRecordingAcrossRecovery = false
    }

    func interruptRecordingAndClearRecoveredTimeline() {
        clearRecoveredRecordingTimeline(keepingCapacity: true)
        markRecordingInterrupted()
    }

    private func interruptRecordingPreservingRecoveredTimeline() {
        preservingRecordingAcrossRecovery = !recoveredRecordingTimeline.isEmpty
        markRecordingInterrupted()
    }

    private func markRecordingInterrupted() {
        recordingInterrupted = true
    }

    private func cancelPendingRecordingRecovery() {
        audioGraphGeneration += 1
        cancelAudioWatchdog()
        audioStartAdmission.cancel()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        cancelConfigRecoveryTimeout()
        configChangeWasRecording = false
        recoveryState.reset()
        publishRecoveryState()
        isRecording = false
        audioLevel = 0
    }

    func loadRecordedSamplesForDictationBenchmark(_ samples: [Float], sampleRate: Double) {
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        sampleBuffer = samples
        recoveredRecordingTimeline.removeAll(keepingCapacity: true)
        preservingRecordingAcrossRecovery = false
        nativeSampleRate = sampleRate
        isRecording = false
        isTranscribing = false
        recordingInterrupted = false
        audioLevel = 0
    }

    private func drainRecordedSamplesForInference() async -> (nativeSampleCount: Int, samples16k: [Float])? {
        drainPendingSamplesIntoSampleBuffer()

        if !recoveredRecordingTimeline.isEmpty {
            recoveredRecordingTimeline.append(sampleBuffer, sampleRate: safeNativeSampleRate())
            sampleBuffer.removeAll(keepingCapacity: true)
            let segments = recoveredRecordingTimeline.drain()
            preservingRecordingAcrossRecovery = false
            let nativeSampleCount = segments.reduce(0) { $0 + $1.samples.count }
            guard nativeSampleCount > 0 else { return nil }
            let resampled = await Task.detached(priority: .userInitiated) {
                var combined: [Float] = []
                for segment in segments {
                    combined.append(contentsOf: AudioResampler.resample(
                        segment.samples,
                        from: segment.sampleRate,
                        to: TranscriptedConstants.parakeetSampleRate
                    ))
                }
                return combined
            }.value
            return (nativeSampleCount, resampled)
        }

        guard !sampleBuffer.isEmpty else { return nil }
        var samples: [Float] = []
        swap(&samples, &sampleBuffer)
        let inputRate = safeNativeSampleRate()
        let nativeSampleCount = samples.count
        let samplesForResampling = samples
        samples.removeAll(keepingCapacity: false)
        let resampled = await Task.detached(priority: .userInitiated) {
            AudioResampler.resample(
                samplesForResampling,
                from: inputRate,
                to: TranscriptedConstants.parakeetSampleRate
            )
        }.value
        return (nativeSampleCount, resampled)
    }

    private func consumeRecordedSamples(
        preparedRecording: RecordedSpeechSamples?
    ) async -> (nativeSampleCount: Int, samples16k: [Float])? {
        guard let preparedRecording else {
            return await drainRecordedSamplesForInference()
        }

        // The persistence snapshot already resampled this exact stopped
        // recording. Consume the native buffers without repeating that work.
        drainPendingSamplesIntoSampleBuffer()
        sampleBuffer.removeAll(keepingCapacity: true)
        clearRecoveredRecordingTimeline(keepingCapacity: true)
        return (
            nativeSampleCount: preparedRecording.nativeSampleCount,
            samples16k: preparedRecording.samples16k
        )
    }

    func snapshotRecordedSamplesForPersistence() async -> RecordedSpeechSamples? {
        drainPendingSamplesIntoSampleBuffer()

        var segments = recoveredRecordingTimeline.segments
        if !sampleBuffer.isEmpty {
            segments.append(RecordedAudioSegment(sampleRate: safeNativeSampleRate(), samples: sampleBuffer))
        }
        let nativeSampleCount = segments.reduce(0) { $0 + $1.samples.count }
        guard nativeSampleCount > 0 else { return nil }

        let samples16k = await Task.detached(priority: .userInitiated) {
            var combined: [Float] = []
            combined.reserveCapacity(nativeSampleCount)
            for segment in segments {
                combined.append(contentsOf: AudioResampler.resample(
                    segment.samples,
                    from: segment.sampleRate,
                    to: TranscriptedConstants.parakeetSampleRate
                ))
            }
            return combined
        }.value
        return RecordedSpeechSamples(nativeSampleCount: nativeSampleCount, samples16k: samples16k)
    }

    // MARK: - Transcription

    func drainRecordedSamplesForExternalTranscription(
        engineName: String,
        preparedRecording: RecordedSpeechSamples? = nil
    ) async -> RecordedSpeechSamples? {
        lastEmptyTranscriptionReason = nil
        guard !isTranscribing else {
            EventReporter.shared.capture(
                level: .warning,
                engine: engineName,
                event: "transcription_already_active",
                message: "transcribe() called while transcription already in progress"
            )
            return nil
        }

        drainPendingSamplesIntoSampleBuffer()

        guard preparedRecording != nil || !sampleBuffer.isEmpty || !recoveredRecordingTimeline.isEmpty else {
            lastEmptyTranscriptionReason = .recordingTooShort
            EventReporter.shared.capture(
                level: .warning,
                engine: engineName,
                event: "no_audio_samples",
                message: "No audio samples in buffer when transcribe() called"
            )
            return nil
        }

        isTranscribing = true
        guard let recorded = await consumeRecordedSamples(preparedRecording: preparedRecording) else {
            finishExternalTranscription()
            return nil
        }
        let nativeCount = recorded.nativeSampleCount
        let resampled = recorded.samples16k
        AppLogger.transcription.info("\(engineName.uppercased()) | resampled \(nativeCount) → \(resampled.count) samples")

        let shortAudioDecision = ParakeetShortAudioGate.dictation(
            nativeSampleCount: nativeCount,
            resampledSampleCount: resampled.count
        )
        guard shortAudioDecision.shouldTranscribe else {
            lastEmptyTranscriptionReason = .recordingTooShort
            let audioDuration = shortAudioDecision.context["audio_duration_s"] ?? "0.00"
            AppLogger.transcription.warning("\(engineName.uppercased()) | skipping transcription for short audio (\(audioDuration)s)")
            EventReporter.shared.capture(
                level: .warning,
                engine: engineName,
                event: shortAudioDecision.event ?? "recording_too_short",
                message: shortAudioDecision.message ?? "Dictation audio too short for transcription",
                context: shortAudioDecision.context
            )
            finishExternalTranscription()
            return nil
        }

        return RecordedSpeechSamples(nativeSampleCount: nativeCount, samples16k: resampled)
    }

    func finishExternalTranscription() {
        finishTranscription()
    }

    private func finishTranscription() {
        isTranscribing = false
        sampleBuffer.removeAll(keepingCapacity: true)
        clearRecoveredRecordingTimeline(keepingCapacity: true)
    }

    var hasActiveASRWork: Bool {
        asrInferenceActivity.isActive
            || asrInferenceHandoffCount > 0
            || !asrInferenceWaiters.isEmpty
            || pureSampleTranscriptionActivityCount > 0
    }

    private func beginPureSampleTranscriptionActivity() {
        pureSampleTranscriptionActivityCount += 1
    }

    private func finishPureSampleTranscriptionActivity() {
        pureSampleTranscriptionActivityCount = max(0, pureSampleTranscriptionActivityCount - 1)
    }

    private func beginASRInference() async {
        if asrInferenceActivity.canStartImmediately(reservedHandoffCount: asrInferenceHandoffCount) {
            asrInferenceActivity.begin()
            return
        }

        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "asr_inference_deferred",
            message: "ASR inference request queued behind active decoder work",
            context: [
                "active_count": "\(asrInferenceActivity.activeCount)",
                "handoff_count": "\(asrInferenceHandoffCount)",
                "waiter_count": "\(asrInferenceWaiters.count)"
            ]
        )
        await withCheckedContinuation { continuation in
            asrInferenceWaiters.append(continuation)
        }
        asrInferenceHandoffCount = max(0, asrInferenceHandoffCount - 1)
        asrInferenceActivity.begin()
    }

    private func finishASRInference() {
        asrInferenceActivity.finish()
        if let next = asrInferenceWaiters.first {
            asrInferenceWaiters.removeFirst()
            asrInferenceHandoffCount += 1
            next.resume()
            return
        }
    }

    private func runASRInference(
        manager: AsrManager,
        samples: [Float]
    ) async throws -> String {
        await beginASRInference()
        do {
            try Task.checkCancellation()
            // FluidAudio 0.15.x hands decoder-state ownership to the caller. Every batch
            // segment gets a fresh state so concurrent mic/system segments can never
            // contaminate each other's decoder context (0.7.9 kept per-source state
            // internally, keyed by the removed `source:` parameter).
            let decoderLayers = await manager.decoderLayerCount
            var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
            let result = try await manager.transcribe(samples, decoderState: &decoderState)
            let text = withExtendedLifetime(result) {
                String(result.text)
            }
            finishASRInference()
            return text
        } catch {
            finishASRInference()
            throw error
        }
    }

    func transcribe(preparedRecording: RecordedSpeechSamples? = nil) async -> String? {
        lastEmptyTranscriptionReason = nil
        guard !isTranscribing else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "transcription_already_active",
                message: "transcribe() called while transcription already in progress")
            return nil
        }
        drainPendingSamplesIntoSampleBuffer()
        guard preparedRecording != nil || !sampleBuffer.isEmpty || !recoveredRecordingTimeline.isEmpty else {
            lastEmptyTranscriptionReason = .recordingTooShort
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "no_audio_samples",
                message: "No audio samples in buffer when transcribe() called")
            return nil
        }
        guard let manager = asrManager, asrManagerReady else {
            AppLogger.transcription.error("PARAKEET | ASR manager not available")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "asr_manager_unavailable",
                message: "ASR manager not available for transcription")
            return nil
        }

        isTranscribing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        guard let recorded = await consumeRecordedSamples(preparedRecording: preparedRecording) else {
            finishTranscription()
            return nil
        }
        let nativeCount = recorded.nativeSampleCount
        let resampled = recorded.samples16k
        AppLogger.transcription.info("PARAKEET | resampled \(nativeCount) → \(resampled.count) samples")

        let shortAudioDecision = ParakeetShortAudioGate.dictation(
            nativeSampleCount: nativeCount,
            resampledSampleCount: resampled.count
        )
        guard shortAudioDecision.shouldTranscribe else {
            lastEmptyTranscriptionReason = .recordingTooShort
            let audioDuration = shortAudioDecision.context["audio_duration_s"] ?? "0.00"
            AppLogger.transcription.warning("PARAKEET | skipping transcription for short audio (\(audioDuration)s)")
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: shortAudioDecision.event ?? "recording_too_short",
                message: shortAudioDecision.message ?? "Dictation audio too short for transcription",
                context: shortAudioDecision.context
            )
            finishTranscription()
            return nil
        }

        do {
            let resultText = try await runASRInference(
                manager: manager,
                samples: resampled
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let trimmed = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
            let corrected = CustomDictionaryTextProcessor.apply(to: trimmed)

            let audioDuration = Double(resampled.count) / TranscriptedConstants.parakeetSampleRate
            let rtf = audioDuration > 0 ? elapsed / audioDuration : 0
            AppLogger.transcription.info("PARAKEET | transcribed in \(String(format: "%.2f", elapsed))s, chars=\(corrected.count)")

            if trimmed.isEmpty {
                let analysis = DictationAudioRecovery.analyze(
                    samples: resampled,
                    sampleRate: TranscriptedConstants.parakeetSampleRate
                )
                var emptyContext = ["samples": "\(nativeCount)"]
                emptyContext.merge(analysis.context) { current, _ in current }

                if let retrySamples = DictationAudioRecovery.retrySamples(
                    from: resampled,
                    sampleRate: TranscriptedConstants.parakeetSampleRate,
                    analysis: analysis
                ) {
                    let retryStarted = CFAbsoluteTimeGetCurrent()
                    EventReporter.shared.capture(
                        level: .info,
                        engine: "parakeet",
                        event: "dictation_empty_retry_started",
                        message: "Retrying empty dictation with focused audio",
                        context: emptyContext.merging([
                            "retry_samples": "\(retrySamples.count)",
                            "retry_audio_duration_s": String(format: "%.2f", Double(retrySamples.count) / TranscriptedConstants.parakeetSampleRate),
                        ]) { current, _ in current }
                    )

                    do {
                        let retryResultText = try await runASRInference(
                            manager: manager,
                            samples: retrySamples
                        )
                        let retryElapsed = CFAbsoluteTimeGetCurrent() - retryStarted
                        let retryTrimmed = retryResultText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let retryCorrected = CustomDictionaryTextProcessor.apply(to: retryTrimmed)
                        if !retryTrimmed.isEmpty {
                            let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
                            let retryDuration = Double(retrySamples.count) / TranscriptedConstants.parakeetSampleRate
                            let retryRtf = retryDuration > 0 ? retryElapsed / retryDuration : 0
                            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "transcription_recovered",
                                message: "Recovered empty dictation on retry",
                                context: emptyContext.merging([
                                    "elapsed_s": String(format: "%.3f", totalElapsed),
                                    "retry_elapsed_s": String(format: "%.3f", retryElapsed),
                                    "retry_audio_duration_s": String(format: "%.2f", retryDuration),
                                    "retry_rtf": String(format: "%.3f", retryRtf),
                                    "retry_samples": "\(retrySamples.count)",
                                    "chars": "\(retryCorrected.count)",
                                    "input_samples": "\(nativeCount)",
                                ]) { current, _ in current })
                            finishTranscription()
                            return retryCorrected
                        }

                        emptyContext["retry_empty"] = "true"
                        emptyContext["retry_elapsed_s"] = String(format: "%.3f", retryElapsed)
                        emptyContext["retry_samples"] = "\(retrySamples.count)"
                    } catch {
                        emptyContext["retry_error"] = error.localizedDescription
                    }
                } else if !analysis.hasUsableSpeechSignal {
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "dictation_audio_silent",
                        message: "Dictation audio did not contain enough speech-like signal",
                        context: emptyContext
                    )
                }

                EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "transcription_empty",
                    message: "Parakeet returned no text after \(String(format: "%.1f", elapsed))s inference",
                    context: emptyContext)
                lastEmptyTranscriptionReason = .noSpeech
                finishTranscription()
                return nil
            }

            finishTranscription()

            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "transcription_complete",
                message: "Transcribed in \(String(format: "%.2f", elapsed))s",
                context: [
                    "elapsed_s": String(format: "%.3f", elapsed),
                    "audio_duration_s": String(format: "%.1f", audioDuration),
                    "rtf": String(format: "%.3f", rtf),
                    "chars": "\(corrected.count)",
                    "input_samples": "\(nativeCount)",
                ])
            return corrected
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if let fallbackDecision = ParakeetShortAudioGate.dictationFallback(
                nativeSampleCount: nativeCount,
                resampledSampleCount: resampled.count,
                errorMessage: error.localizedDescription
            ) {
                var fallbackContext = fallbackDecision.context
                fallbackContext["elapsed"] = String(format: "%.2f", elapsed)
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: fallbackDecision.event ?? "recording_too_short",
                    message: fallbackDecision.message ?? "Dictation audio too short for transcription",
                    context: fallbackContext
                )
                lastEmptyTranscriptionReason = .recordingTooShort
                finishTranscription()
                return nil
            }

            AppLogger.transcription.error("PARAKEET | transcription failed: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "transcription_failed",
                message: error.localizedDescription,
                context: ["samples": "\(nativeCount)", "elapsed": String(format: "%.2f", elapsed)])
            lastEmptyTranscriptionReason = .modelFailure
            finishTranscription()
            return nil
        }
    }

    // MARK: - Pure-Sample Transcription (for Meeting pipeline)

    /// Transcribe pre-resampled 16kHz mono Float32 samples directly, bypassing
    /// ParakeetEngine's recording lifecycle and audio buffering.
    ///
    /// Used by `MeetingSTTAdapter` to satisfy Core's `SpeechToTextEngine` protocol:
    /// Core's TranscriptionPipeline owns its own recording (mic + system audio files via
    /// `Audio.swift`), extracts 16kHz samples per speaker segment, and calls this method
    /// once per segment. This is distinct from the app's regular dictation flow, which uses
    /// `startRecording()` / `transcribe()` to capture and transcribe in one shot.
    ///
    /// - Parameters:
    ///   - samples: 16kHz mono Float32 samples. Caller must resample; we do not.
    ///   - source: FluidAudio's `AudioSource` (`.microphone` or `.system`).
    /// - Returns: Transcribed text, trimmed. Empty string if Parakeet returned nothing.
    /// - Throws: Re-throws `AsrManager.transcribe` errors (including model-not-ready).
    func transcribeSamples(_ samples: [Float], source: AudioSource) async throws -> String {
        beginPureSampleTranscriptionActivity()
        defer { finishPureSampleTranscriptionActivity() }

        guard let manager = asrManager, asrManagerReady else {
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "asr_manager_unavailable",
                message: "ASR manager not available for transcribeSamples")
            throw NSError(domain: "ParakeetEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Parakeet ASR manager is not loaded"
            ])
        }
        guard !samples.isEmpty else { return "" }
        let shortAudioDecision = ParakeetShortAudioGate.meetingSegment(
            sampleCount: samples.count,
            sourceDescription: source == .microphone ? "microphone" : "system"
        )
        guard shortAudioDecision.shouldTranscribe else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: shortAudioDecision.event ?? "segment_too_short",
                message: shortAudioDecision.message ?? "Skipped short audio segment before Parakeet transcription",
                context: shortAudioDecision.context
            )
            return ""
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let sourceDescription = source == .microphone ? "microphone" : "system"
        let resultText: String
        do {
            resultText = try await runASRInference(
                manager: manager,
                samples: samples
            )
        } catch {
            if let fallbackDecision = ParakeetShortAudioGate.meetingSegmentFallback(
                sampleCount: samples.count,
                sourceDescription: sourceDescription,
                errorMessage: error.localizedDescription
            ) {
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: fallbackDecision.event ?? "segment_too_short",
                    message: fallbackDecision.message ?? "Skipped short audio segment before Parakeet transcription",
                    context: fallbackDecision.context
                )
                return ""
            }
            throw error
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let trimmed = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = CustomDictionaryTextProcessor.apply(to: trimmed)

        let audioDuration = Double(samples.count) / TranscriptedConstants.parakeetSampleRate
        let rtf = audioDuration > 0 ? elapsed / audioDuration : 0
        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "meeting_segment_transcribed",
            message: "Meeting segment transcribed in \(String(format: "%.2f", elapsed))s",
            context: [
                "elapsed_s": String(format: "%.3f", elapsed),
                "audio_duration_s": String(format: "%.2f", audioDuration),
                "rtf": String(format: "%.3f", rtf),
                "chars": "\(corrected.count)",
            ])

        return corrected
    }

    // MARK: - Cleanup

    func resetAfterFailedRecordingStart() async {
        let pendingRestoreOwner = pendingSystemInputRestore.owner
        sharedMeetingMicTransition.invalidate()
        sharedMeetingMicRecorder.cancel()
        sharedMeetingMicRecording = false
        cancelAudioWatchdog()
        audioStartAdmission.cancel()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        cancelConfigRecoveryTimeout()
        configChangeWasRecording = false
        recoveryState.reset()
        recoveryState.markFormatUnready()
        publishRecoveryState()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        audioGraphGeneration += 1
        let failedStartCleanupOwner = currentAudioEngineQueueOwnerToken()
        guard ownsAudioEngineQueue(failedStartCleanupOwner) else { return }
        isRecording = false
        isTranscribing = false
        audioLevel = 0
        didReceiveAudioSamples = false
        didReceiveNonZeroAudioSamples = false
        recordingStartedOnLikelyBluetoothHandsFreeRoute = false
        sampleBuffer.removeAll(keepingCapacity: true)
        clearRecoveredRecordingTimeline(keepingCapacity: true)
        _ = await releaseIdleAudioHardware(
            removeTap: true,
            expectedGeneration: failedStartCleanupOwner.graphOwner.generation
        )
        await restorePendingSystemInputAfterRecording(
            ownedBy: pendingRestoreOwner,
            operation: "reset_after_failed_recording_start"
        )
    }

    func abandonBlockedRecordingStart(reason: String) {
        let pendingRestoreOwner = pendingSystemInputRestore.owner
        sharedMeetingMicTransition.invalidate()
        sharedMeetingMicRecorder.cancel()
        sharedMeetingMicRecording = false
        let didReplaceBlockedGraph = cancelAudioWatchdog()
        audioStartAdmission.cancel()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        cancelConfigRecoveryTimeout()
        configChangeWasRecording = false
        recoveryState.reset()
        recoveryState.markFormatUnready()
        publishRecoveryState()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        isRecording = false
        isTranscribing = false
        audioLevel = 0
        didReceiveAudioSamples = false
        didReceiveNonZeroAudioSamples = false
        recordingStartedOnLikelyBluetoothHandsFreeRoute = false
        sampleBuffer.removeAll(keepingCapacity: true)
        clearRecoveredRecordingTimeline(keepingCapacity: true)
        schedulePendingSystemInputRestore(
            ownedBy: pendingRestoreOwner,
            operation: "abandon_blocked_recording_start"
        )
        if !didReplaceBlockedGraph {
            abandonBlockedAudioEngine(reason: reason)
        }
    }

    func cancel() {
        let pendingRestoreOwner = pendingSystemInputRestore.owner
        sharedMeetingMicTransition.invalidate()
        sharedMeetingMicRecorder.cancel()
        sharedMeetingMicRecording = false
        cancelAudioWatchdog()
        audioStartAdmission.cancel()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        cancelConfigRecoveryTimeout()
        configChangeWasRecording = false
        recoveryState.reset()
        publishRecoveryState()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        if isRecording {
            isRecording = false
            audioLevel = 0
        }
        audioGraphGeneration += 1
        let cleanupGeneration = audioGraphGeneration
        schedulePendingSystemInputRestore(ownedBy: pendingRestoreOwner, operation: "cancel")
        Task { @MainActor [weak self] in
            await self?.releaseIdleAudioHardware(removeTap: true, expectedGeneration: cleanupGeneration)
        }
        sampleBuffer.removeAll()
        clearRecoveredRecordingTimeline(keepingCapacity: false)
        isTranscribing = false
    }

    @discardableResult
    private func releaseIdleAudioHardware(
        removeTap: Bool,
        expectedGeneration: Int? = nil
    ) async -> ParakeetAudioEngineQueueOwnerToken? {
        if let expectedGeneration, expectedGeneration != audioGraphGeneration {
            return nil
        }
        audioGraphGeneration += 1
        let idleCleanupOwner = currentAudioEngineQueueOwnerToken()
        if removeTap {
            await removeRecordingTap(force: true)
        }
        guard ownsAudioEngineQueue(idleCleanupOwner) else { return nil }
        await stopAudioEngine()
        guard ownsAudioEngineQueue(idleCleanupOwner) else { return nil }
        isEnginePrewarmed = false
        return idleCleanupOwner
    }

    private func cancelAudioWatchdogForRecordingStart() {
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
        guard let zombieRecoveryStartGeneration,
              zombieRecoveryState.canContinue(generation: zombieRecoveryStartGeneration) else {
            cancelZombieEngineRecovery()
            return
        }
    }

    @discardableResult
    private func cancelZombieEngineRecovery() -> Bool {
        zombieRecoveryTask?.cancel()
        audioStartCancellationState?.cancel()
        audioStartCancellationState = nil
        var didReplaceBlockedGraph = false
        if let blockedLease = audioEngineWorkOwnership.claimPendingWorkForSuccessor(
            currentEngine: audioEngine,
            currentQueue: audioEngineQueue
        ) {
            // Cancellation may advance logical ownership before this method
            // runs. If reset or start work still owns these exact resources,
            // replace both before successor cleanup can enqueue.
            let reason: String
            switch blockedLease.phase {
            case .zombieReset:
                reason = "zombie_engine_reset_cancelled"
            case .audioStart:
                reason = "audio_engine_start_cancelled"
            case .deviceRecoverySnapshot:
                reason = "device_recovery_snapshot_cancelled"
            }
            if blockedLease.phase == .audioStart {
                audioStartAdmission.finish(owner: blockedLease.owner)
            }
            didReplaceBlockedGraph = abandonBlockedAudioEngine(reason: reason)
        }
        zombieRecoveryTask = nil
        zombieRecoveryStartGeneration = nil
        if let terminal = zombieRecoveryState.cancelActiveAttempt() {
            reportZombieEngineRecoveryTerminal(terminal)
        }
        return didReplaceBlockedGraph
    }

    @discardableResult
    func cancelAudioWatchdog() -> Bool {
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
        return cancelZombieEngineRecovery()
    }

    func cleanup() {
        let pendingRestoreOwner = pendingSystemInputRestore.owner
        sharedMeetingMicTransition.invalidate()
        sharedMeetingMicRecorder.cancel()
        sharedMeetingMicRecording = false
        isShuttingDown = true
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
        schedulePendingSystemInputRestore(ownedBy: pendingRestoreOwner, operation: "cleanup")
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
        modelInitializationTask?.cancel()
        modelFilePrefetchTask?.cancel()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        unregisterDefaultInputDeviceListener(inputDeviceChangeListener)
        audioEngineQueue.async { [audioEngine] in
            ParakeetEngine.safelyRemoveInputTap(on: audioEngine)
            audioEngine.reset()
        }
        ParakeetRetiredAudioEngineStore.shared.retire(audioEngine, reason: "deinit")
        let mgr = asrManager
        Task { await mgr?.cleanup() }
    }
}

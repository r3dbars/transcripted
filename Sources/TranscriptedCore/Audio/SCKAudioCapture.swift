import AVFoundation
import Combine
import CoreMedia
import QuartzCore
import ScreenCaptureKit

/// ScreenCaptureKit-based system audio capture (macOS 26+).
///
/// Uses `SCStream` with audio-only output — no screen pixels are captured.
/// On macOS 26, this triggers the lighter "System Audio Recording Only" permission
/// tier instead of full Screen Recording. The permission dialog behaves like the
/// microphone prompt: click Allow and it works immediately — no app restart needed.
///
/// The public interface matches `SystemAudioCaptureEngine`, which `Audio`
/// resolves through its systemAudioCaptureFactory. This is the only backend
/// left; the CoreAudio process-tap one was deleted once nothing constructed it.
@available(macOS 26.0, *)
final class SCKAudioCapture: NSObject, ObservableObject, SystemAudioCaptureEngine, SCStreamDelegate, @unchecked Sendable {
    @Published var errorMessage: String?
    // Recovery/health event reporting seam back to `Audio`, so its bounded
    // mid-recording stream recovery counts toward the same
    // `Audio.deviceSwitchCount` / `Audio.recordingGaps` the mic path already
    // feeds into `RecordingHealthInfo.captureQuality`. Only sent from
    // `handleMidRecordingFailure`'s recovery block, which `isRecovering`
    // already serializes to one in-flight attempt at a time.
    let recoveryEventSubject = PassthroughSubject<SystemAudioRecoveryEvent, Never>()

    enum StreamPhase: String {
        case idle
        case prepared
        case starting
        case capturing
        case stopping
        case stopTimedOut = "stop_timed_out"
    }

    struct StopTransition {
        let stream: any SCKStreamControlling
        let generation: UInt64
        let shouldRequestStop: Bool
    }

    struct CurrentStreamState {
        let stream: (any SCKStreamControlling)?
        let generation: UInt64?
        let isCapturing: Bool
        let isWaitingForTimedOutStopCallback: Bool
    }

    var stream: (any SCKStreamControlling)?
    var streamOutput: SCKAudioStreamOutput?
    var _audioFormat: AVAudioFormat?
    var _isCapturing = false
    var bufferCallback: ((AVAudioPCMBuffer) -> Void)?
    var _generationEpoch = SupersessionEpoch()
    var streamGeneration: UInt64?
    var streamPhase: StreamPhase = .idle
    var isWaitingForTimedOutStopCallback = false
    var recoveryAttempts = 0
    var isRecovering = false
    var recoveryEpochState = SCKRecoveryEpochState()
    // Guards stream identity/generation/phase, output ownership, `_isCapturing`,
    // `recoveryAttempts`, `isRecovering`, and `recoveryEpochState` so the
    // buffer-stall watchdog (`checkWatchdog`, on `watchdogQueue`), the
    // `SCStreamDelegate` callback (on ScreenCaptureKit's delegate queue), and
    // the recovery block they spawn (on a `.userInitiated` global queue)
    // cannot race each other's guard-check-then-set of these fields — e.g.
    // both a buffer-stall and a `didStopWithError` callback observing
    // "not yet recovering" and both kicking off a recovery attempt. Official
    // stop paths also invalidate recovery while holding this same lock.
    let captureStateLock = NSLock()
    private static let defaultCallbackTimeoutSeconds = 8
    private static let permissionPromptCallbackTimeoutSeconds = 120
    private static let defaultCallbackTimeout: DispatchTimeInterval = .seconds(defaultCallbackTimeoutSeconds)
    private static let permissionPromptCallbackTimeout: DispatchTimeInterval = .seconds(permissionPromptCallbackTimeoutSeconds)
    let callbackTimeout: DispatchTimeInterval
    let callbackTimeoutSeconds: Int
    let testHooks: SCKAudioCaptureTestHooks
    static let maxRecoveryAttempts = AudioRecoveryTuning.SystemAudio.maxRecoveryAttempts
    static let bufferStallTimeoutSeconds: CFTimeInterval = AudioRecoveryTuning.SystemAudio.stallTimeoutSeconds
    let watchdogQueue = DispatchQueue(label: "SCKAudioCapture.watchdog", qos: .utility)
    var watchdogTimer: DispatchSourceTimer?
    let watchdogLock = NSLock()
    var _lastBufferTime: CFTimeInterval = CACurrentMediaTime()
    var _hasReceivedFirstBuffer = false

    var diagnosticBackendName: String { "screen_capture_kit" }

    // Buffer statistics (thread-safe)
    var _totalBuffers: Int = 0
    var _buffersWithData: Int = 0
    let statsLock = NSLock()

    override init() {
        callbackTimeout = Self.defaultCallbackTimeout
        callbackTimeoutSeconds = Self.defaultCallbackTimeoutSeconds
        testHooks = SCKAudioCaptureTestHooks()
        super.init()
    }

    init(
        callbackTimeout: DispatchTimeInterval,
        callbackTimeoutSeconds: Int,
        testHooks: SCKAudioCaptureTestHooks = SCKAudioCaptureTestHooks()
    ) {
        self.callbackTimeout = callbackTimeout
        self.callbackTimeoutSeconds = callbackTimeoutSeconds
        self.testHooks = testHooks
        super.init()
    }

    var audioFormat: AVAudioFormat? {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return _audioFormat
    }
    var deliversOwnedAudioBuffers: Bool { true }

    var bufferSuccessRate: Double {
        statsLock.lock()
        defer { statsLock.unlock() }
        guard _totalBuffers > 0 else { return 0.0 }
        return Double(_buffersWithData) / Double(_totalBuffers)
    }

    var errorMessagePublisher: AnyPublisher<String?, Never> {
        $errorMessage.eraseToAnyPublisher()
    }

    var recoveryEventPublisher: AnyPublisher<SystemAudioRecoveryEvent, Never> {
        recoveryEventSubject.eraseToAnyPublisher()
    }

    // MARK: - Lifecycle

    func prepare() throws {
        try prepare(preservingRecoveryToken: nil)
    }

    func prepare(preservingRecoveryToken recoveryToken: SCKRecoveryEpochState.Token?) throws {
        try validateRecoveryToken(recoveryToken)
        AppLogger.audioSystem.info("SCKAudioCapture: preparing ScreenCaptureKit audio stream")
        try stopCurrentStreamBeforePrepare(preservingRecoveryToken: recoveryToken)
        try validateRecoveryToken(recoveryToken)
        let prepareGeneration = incrementGeneration()

        // Fetch shareable content. On first use this can be held by the macOS
        // permission prompt, so it gets a longer timeout than normal callbacks.
        // Heap-box the result so a late callback after cancel/timeout cannot
        // write into prepare()'s stack frame.
        let fetchState = SCKShareableContentFetchState()

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { result, error in
            fetchState.complete(content: result, error: error)
        }
        try Self.waitForCallback(
            fetchState.semaphore,
            operation: "shareable content fetch",
            timeout: Self.permissionPromptCallbackTimeout,
            timeoutSeconds: Self.permissionPromptCallbackTimeoutSeconds,
            shouldAbort: { [self] in
                self.currentGeneration() != prepareGeneration
            }
        )
        try validateRecoveryToken(recoveryToken)
        guard currentGeneration() == prepareGeneration else {
            throw SCKRecoveryCancelledError()
        }

        let fetch = fetchState.result()
        if let error = fetch.error {
            AppLogger.audioSystem.error("SCKAudioCapture: failed to get shareable content", ["error": error.localizedDescription])
            throw error
        }

        guard let display = fetch.content?.displays.first else {
            throw "SCKAudioCapture: no display found"
        }

        // Content filter scoped to the full display — captures all app audio.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Audio-only configuration. We never add a .screen output, so macOS 26
        // categorizes this under "System Audio Recording Only".
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // Minimal video settings — the stream requires a config even though we
        // never attach a screen output. Keep overhead negligible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        guard currentGeneration() == prepareGeneration else {
            throw AudioCaptureStaleSessionError()
        }

        // Pre-create the format the WAV file will use. ScreenCaptureKit delivers
        // float32 non-interleaved audio matching the configured rate/channels.
        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )

        let preparedStream = SCStream(filter: filter, configuration: config, delegate: self)
        guard currentGeneration() == prepareGeneration else {
            throw AudioCaptureStaleSessionError()
        }
        guard installPreparedStreamIfCurrent(
            preparedStream,
            audioFormat: audioFormat,
            recoveryToken: recoveryToken,
            generation: prepareGeneration
        ) else {
            throw SCKRecoveryCancelledError()
        }

        AppLogger.audioSystem.info("SCKAudioCapture: stream prepared", [
            "sampleRate": "48000",
            "channels": "2"
        ])
    }

    func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws {
        try start(bufferCallback: bufferCallback, recoveryToken: nil)
    }

    func start(
        bufferCallback: @escaping (AVAudioPCMBuffer) -> Void,
        recoveryToken: SCKRecoveryEpochState.Token?
    ) throws {
        try validateRecoveryToken(recoveryToken)
        let initialState = currentStreamState()
        guard !initialState.isWaitingForTimedOutStopCallback else {
            AppLogger.audioSystem.warning("SCKAudioCapture: refusing to start stream while previous stop is still pending")
            throw SCKCaptureTimeoutError(operation: "previous stop cleanup")
        }
        guard !initialState.isCapturing else {
            AppLogger.audioSystem.warning("SCKAudioCapture: refusing to start stream because capture is already active")
            throw "SCKAudioCapture: capture already active"
        }
        guard let stream = initialState.stream else {
            AppLogger.audioSystem.info("SCKAudioCapture: auto-preparing in start()")
            try prepare(preservingRecoveryToken: recoveryToken)
            try validateRecoveryToken(recoveryToken)
            return try start(bufferCallback: bufferCallback, recoveryToken: recoveryToken)
        }
        guard let startGeneration = initialState.generation else {
            throw AudioCaptureStaleSessionError()
        }
        let streamIdentity = stream.captureIdentity

        resetBufferWatchdogState()

        // Output handler converts CMSampleBuffer → AVAudioPCMBuffer
        let output = SCKAudioStreamOutput { [weak self] buffer in
            guard let self = self else { return }
            guard self.isCurrentCapturingStream(identity: streamIdentity, generation: startGeneration) else {
                return
            }
            self.statsLock.lock()
            self._totalBuffers += 1
            self._buffersWithData += 1
            self.statsLock.unlock()
            self.markBufferReceived()
            bufferCallback(buffer)
        }
        let queue = DispatchQueue(label: "SCKAudioCapture.output", qos: .userInitiated)
        var didRequestStart = false
        let semaphore = DispatchSemaphore(value: 0)
        let callbackState = SCKStartCallbackState()
        do {
            // Output installation, the `.starting` claim, and the start request
            // happen under the ownership lock. An official stop therefore wins
            // before the request or takes responsibility for stopping this exact
            // stream after the request; it cannot slip into the old validated-but-
            // not-yet-started gap.
            try requestStartIfCurrent(
                stream: stream,
                generation: startGeneration,
                output: output,
                queue: queue,
                bufferCallback: bufferCallback,
                recoveryToken: recoveryToken
            ) { error in
                callbackState.complete(with: error)
                semaphore.signal()
            }
            didRequestStart = true
            try Self.waitForCallback(
                semaphore,
                operation: "start capture",
                timeout: callbackTimeout,
                timeoutSeconds: callbackTimeoutSeconds
            )
            try validateRecoveryToken(recoveryToken)

            if let error = callbackState.completedError() {
                throw error
            }

            guard transitionToCapturingAndStartWatchdogIfCurrent(
                recoveryToken: recoveryToken,
                generation: startGeneration,
                streamIdentity: streamIdentity
            ) else {
                throw SCKRecoveryCancelledError()
            }
            // Recovery success must wait for a real buffer before publishing
            // healthy. A non-recovery start can clear the error immediately.
            if recoveryToken == nil {
                publishHealthyIfCurrent(identity: streamIdentity, generation: startGeneration)
            }
            AppLogger.audioSystem.info("SCKAudioCapture: now capturing system audio")
        } catch {
            let recoveryWasCancelled = error is SCKRecoveryCancelledError
            if recoveryWasCancelled {
                AppLogger.audioSystem.info("SCKAudioCapture: cancelled stale recovery start")
            } else {
                AppLogger.audioSystem.error("SCKAudioCapture: start failed", ["error": error.localizedDescription])
            }
            if didRequestStart {
                stopStreamAndCleanupAfterFailedStartIfOwned(
                    stream,
                    generation: startGeneration
                )
            } else {
                cleanupPreparedStreamReferenceIfCurrent(
                    stream,
                    generation: startGeneration
                )
            }
            if !recoveryWasCancelled {
                publishErrorMessage(error.localizedDescription)
            }
            throw error
        }
    }

    func stop() {
        stop(preservingRecoveryToken: nil)
    }

    private func stop(preservingRecoveryToken recoveryToken: SCKRecoveryEpochState.Token?) {
        guard let transition = transitionToStopped(preservingRecoveryToken: recoveryToken) else { return }
        stopWatchdog()
        guard transition.shouldRequestStop else { return }
        transition.stream.stopCapture { [weak self, stream = transition.stream] error in
            if let error = error {
                AppLogger.audioSystem.warning("SCKAudioCapture: stop error", ["error": error.localizedDescription])
            }
            self?.cleanupIfCurrent(generation: transition.generation, stream: stream)
        }
    }

    func stopSync() {
        stopSync(preservingRecoveryToken: nil)
    }

    func stopSync(preservingRecoveryToken recoveryToken: SCKRecoveryEpochState.Token?) {
        guard let transition = transitionToStopped(preservingRecoveryToken: recoveryToken) else { return }
        stopWatchdog()
        guard transition.shouldRequestStop else { return }
        if stopStreamSynchronously(transition.stream, cleanupAfterLateCallback: { [weak self, stream = transition.stream] in
            self?.cleanupIfCurrent(generation: transition.generation, stream: stream)
        }) {
            cleanupIfCurrent(generation: transition.generation, stream: transition.stream)
        } else {
            retainStreamReferenceAfterTimedOutStop(
                transition.stream,
                generation: transition.generation
            )
        }
    }

    private func stopCurrentStreamBeforePrepare(
        preservingRecoveryToken recoveryToken: SCKRecoveryEpochState.Token?
    ) throws {
        guard !currentStreamState().isWaitingForTimedOutStopCallback else {
            AppLogger.audioSystem.warning("SCKAudioCapture: refusing to prepare new stream while previous stop is still pending")
            throw SCKCaptureTimeoutError(operation: "previous stop cleanup")
        }

        stopSync(preservingRecoveryToken: recoveryToken)
        try validateRecoveryToken(recoveryToken)

        let state = currentStreamState()
        guard !state.isWaitingForTimedOutStopCallback, state.stream == nil else {
            AppLogger.audioSystem.warning("SCKAudioCapture: refusing to prepare new stream because previous stream is still stopping")
            throw SCKCaptureTimeoutError(operation: "previous stop cleanup")
        }
    }

    // Keep returning raw UInt64 here so the many `generation: UInt64` call
    // sites below (streamGeneration comparisons, StopTransition, etc. — out of
    // scope for this migration, see the file-level note near `streamGeneration`)
    // don't need to change. `.rawValue` is the primitive's documented interop
    // accessor for exactly this "raw counter threaded through logging/params"
    // shape.
    func incrementGeneration() -> UInt64 {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return _generationEpoch.begin().rawValue
    }

    private func currentGeneration() -> UInt64 {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return _generationEpoch.snapshot().rawValue
    }

    func currentStreamState() -> CurrentStreamState {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return CurrentStreamState(
            stream: stream,
            generation: streamGeneration,
            isCapturing: _isCapturing,
            isWaitingForTimedOutStopCallback: isWaitingForTimedOutStopCallback
        )
    }

    private func validateRecoveryToken(_ token: SCKRecoveryEpochState.Token?) throws {
        guard let token else { return }
        guard isRecoveryCurrent(token) else {
            throw SCKRecoveryCancelledError()
        }
    }

    private func isRecoveryCurrent(_ token: SCKRecoveryEpochState.Token) -> Bool {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return recoveryEpochState.isCurrent(token)
    }

    func shouldContinueRecovery(
        _ token: SCKRecoveryEpochState.Token,
        at checkpoint: String
    ) -> Bool {
        guard isRecoveryCurrent(token) else {
            AppLogger.audioSystem.info("SCKAudioCapture: recovery cancelled", [
                "checkpoint": checkpoint
            ])
            return false
        }
        return true
    }

    func installPreparedStreamIfCurrent(
        _ preparedStream: any SCKStreamControlling,
        audioFormat: AVAudioFormat?,
        recoveryToken: SCKRecoveryEpochState.Token?,
        generation: UInt64
    ) -> Bool {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        if let recoveryToken, !recoveryEpochState.isCurrent(recoveryToken) {
            return false
        }
        guard _generationEpoch.snapshot().rawValue == generation,
              stream == nil,
              !isWaitingForTimedOutStopCallback else {
            return false
        }
        _audioFormat = audioFormat
        stream = preparedStream
        streamGeneration = generation
        streamPhase = .prepared
        return true
    }

    private func requestStartIfCurrent(
        stream expectedStream: any SCKStreamControlling,
        generation: UInt64,
        output: SCKAudioStreamOutput,
        queue: DispatchQueue,
        bufferCallback: @escaping (AVAudioPCMBuffer) -> Void,
        recoveryToken: SCKRecoveryEpochState.Token?,
        completion: @escaping @Sendable (Error?) -> Void
    ) throws {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }

        if let recoveryToken, !recoveryEpochState.isCurrent(recoveryToken) {
            throw SCKRecoveryCancelledError()
        }
        guard !isWaitingForTimedOutStopCallback,
              !_isCapturing,
              streamGeneration == generation,
              stream?.captureIdentity == expectedStream.captureIdentity,
              streamPhase == .prepared else {
            throw SCKRecoveryCancelledError()
        }

        do {
            try expectedStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
            self.streamOutput = output
            self.bufferCallback = bufferCallback
            if !isRecovering {
                recoveryAttempts = 0
            }
            streamPhase = .starting
            expectedStream.startCapture(completionHandler: completion)
        } catch {
            streamOutput = nil
            self.bufferCallback = nil
            streamPhase = .prepared
            throw error
        }
    }

    func isCurrentCapturingStream(identity: ObjectIdentifier, generation: UInt64) -> Bool {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return _isCapturing
            && streamPhase == .capturing
            && streamGeneration == generation
            && stream?.captureIdentity == identity
    }

    private func transitionToStopped(
        preservingRecoveryToken recoveryToken: SCKRecoveryEpochState.Token?
    ) -> StopTransition? {
        var didCleanupPreparedStream = false
        captureStateLock.lock()
        if recoveryEpochState.cancel(preserving: recoveryToken) {
            isRecovering = false
        }
        _generationEpoch.invalidate()

        guard let stream, let generation = streamGeneration else {
            _isCapturing = false
            streamPhase = .idle
            captureStateLock.unlock()
            return nil
        }

        let transition: StopTransition
        switch streamPhase {
        case .prepared, .idle:
            didCleanupPreparedStream = clearStreamStateLocked(
                expectedIdentity: stream.captureIdentity,
                expectedGeneration: generation
            )
            transition = StopTransition(
                stream: stream,
                generation: generation,
                shouldRequestStop: false
            )
        case .starting, .capturing:
            _isCapturing = false
            streamPhase = .stopping
            transition = StopTransition(
                stream: stream,
                generation: generation,
                shouldRequestStop: true
            )
        case .stopping, .stopTimedOut:
            _isCapturing = false
            transition = StopTransition(
                stream: stream,
                generation: generation,
                shouldRequestStop: false
            )
        }
        captureStateLock.unlock()

        if didCleanupPreparedStream {
            finishCleanupSideEffects()
        }
        return transition
    }

    private func transitionToCapturingAndStartWatchdogIfCurrent(
        recoveryToken: SCKRecoveryEpochState.Token?,
        generation: UInt64,
        streamIdentity: ObjectIdentifier
    ) -> Bool {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        guard streamGeneration == generation,
              stream?.captureIdentity == streamIdentity,
              streamPhase == .starting else {
            return false
        }
        if let recoveryToken {
            guard recoveryEpochState.isCurrent(recoveryToken) else { return false }
        } else {
            recoveryEpochState.enableForActiveCapture()
        }
        streamPhase = .capturing
        _isCapturing = true
        startWatchdog(generation: generation)
        return true
    }

    func activeFailureCallback(generation: UInt64) -> ((AVAudioPCMBuffer) -> Void)? {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        guard _isCapturing,
              streamPhase == .capturing,
              streamGeneration == generation else {
            return nil
        }
        return bufferCallback
    }

    func isActiveCaptureGeneration(_ generation: UInt64) -> Bool {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return _isCapturing
            && streamPhase == .capturing
            && streamGeneration == generation
    }


    func stream(_ stream: SCStream, didStopWithError error: Error) {
        handleStoppedStream(identity: ObjectIdentifier(stream), error: error)
    }

    func handleStoppedStream(identity: ObjectIdentifier, error: Error) {
        captureStateLock.lock()
        let generation: UInt64?
        if _isCapturing,
           streamPhase == .capturing,
           stream?.captureIdentity == identity {
            generation = streamGeneration
        } else {
            generation = nil
        }
        captureStateLock.unlock()

        guard let generation else {
            AppLogger.audioSystem.info("SCKAudioCapture: ignoring stale stream stop callback")
            return
        }
        AppLogger.audioSystem.error("SCKAudioCapture: stream stopped with error", [
            "error": error.localizedDescription
        ])
        handleMidRecordingFailure(
            "System audio failed - ScreenCaptureKit stopped delivering audio.",
            generation: generation,
            attemptRestart: true
        )
    }


}

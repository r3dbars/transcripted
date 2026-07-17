import AVFoundation
import Combine
import CoreMedia
import QuartzCore
import ScreenCaptureKit

/// Lock-owned coordination for the one bounded ScreenCaptureKit recovery.
///
/// An official stop disables recovery and advances the epoch. Internal cleanup
/// may preserve the active token so the same recovery can continue, but a stale
/// token can never become current again.
struct SCKRecoveryEpochState {
    typealias Token = UInt64

    private(set) var epoch: UInt64 = 0
    private(set) var activeToken: Token?
    private(set) var acceptsRecovery = false

    mutating func enableForActiveCapture() {
        epoch &+= 1
        activeToken = nil
        acceptsRecovery = true
    }

    mutating func begin() -> Token? {
        guard acceptsRecovery else { return nil }
        epoch &+= 1
        activeToken = epoch
        return epoch
    }

    @discardableResult
    mutating func cancel(preserving token: Token? = nil) -> Bool {
        if let token, isCurrent(token) {
            return false
        }
        epoch &+= 1
        activeToken = nil
        acceptsRecovery = false
        return true
    }

    func isCurrent(_ token: Token) -> Bool {
        acceptsRecovery && activeToken == token && epoch == token
    }

    @discardableResult
    mutating func finish(_ token: Token) -> Bool {
        guard isCurrent(token) else { return false }
        activeToken = nil
        return true
    }
}

private struct SCKRecoveryCancelledError: LocalizedError {
    var errorDescription: String? {
        "ScreenCaptureKit recovery was cancelled."
    }
}

@available(macOS 26.0, *)
protocol SCKStreamControlling: AnyObject {
    var captureIdentity: ObjectIdentifier { get }

    func addStreamOutput(
        _ output: any SCStreamOutput,
        type: SCStreamOutputType,
        sampleHandlerQueue: DispatchQueue?
    ) throws
    func startCapture(completionHandler: (@Sendable (Error?) -> Void)?)
    func stopCapture(completionHandler: (@Sendable (Error?) -> Void)?)
}

@available(macOS 26.0, *)
extension SCStream: SCKStreamControlling {
    var captureIdentity: ObjectIdentifier { ObjectIdentifier(self) }
}

@available(macOS 26.0, *)
struct SCKAudioCaptureTestHooks: Sendable {
    var afterCleanupValidationWhileLocked: (@Sendable () -> Void)?
}

@available(macOS 26.0, *)
struct SCKAudioCaptureStateSnapshot: Equatable, Sendable {
    let streamIdentity: ObjectIdentifier?
    let generation: UInt64?
    let phase: String
    let isCapturing: Bool
    let isWaitingForTimedOutStopCallback: Bool
    let recoveryAttempts: Int
}

/// ScreenCaptureKit-based system audio capture (macOS 26+).
///
/// Uses `SCStream` with audio-only output — no screen pixels are captured.
/// On macOS 26, this triggers the lighter "System Audio Recording Only" permission
/// tier instead of full Screen Recording. The permission dialog behaves like the
/// microphone prompt: click Allow and it works immediately — no app restart needed.
///
/// The public interface matches `SystemAudioCaptureEngine` so `Audio` can swap
/// between this and the CoreAudio-based `SystemAudioCapture` transparently.
@available(macOS 26.0, *)
private struct SCKCaptureTimeoutError: LocalizedError {
    let operation: String

    var errorDescription: String? {
        "ScreenCaptureKit \(operation) timed out."
    }
}

@available(macOS 26.0, *)
private final class SCKStopCallbackState {
    private let lock = NSLock()
    private var didComplete = false
    private var didTimeOut = false

    func complete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        didComplete = true
        return didTimeOut
    }

    func markTimedOutUnlessComplete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didComplete { return false }
        didTimeOut = true
        return true
    }
}

@available(macOS 26.0, *)
private final class SCKStartCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func complete(with error: Error?) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func completedError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

@available(macOS 26.0, *)
final class SCKAudioCapture: NSObject, ObservableObject, SystemAudioCaptureEngine, SCStreamDelegate, @unchecked Sendable {
    @Published var errorMessage: String?

    private enum StreamPhase: String {
        case idle
        case prepared
        case starting
        case capturing
        case stopping
        case stopTimedOut = "stop_timed_out"
    }

    private struct StopTransition {
        let stream: any SCKStreamControlling
        let generation: UInt64
        let shouldRequestStop: Bool
    }

    private struct CurrentStreamState {
        let stream: (any SCKStreamControlling)?
        let generation: UInt64?
        let isCapturing: Bool
        let isWaitingForTimedOutStopCallback: Bool
    }

    private var stream: (any SCKStreamControlling)?
    private var streamOutput: SCKAudioStreamOutput?
    private var _audioFormat: AVAudioFormat?
    private var _isCapturing = false
    private var bufferCallback: ((AVAudioPCMBuffer) -> Void)?
    private var _generation: UInt64 = 0
    private var streamGeneration: UInt64?
    private var streamPhase: StreamPhase = .idle
    private var isWaitingForTimedOutStopCallback = false
    private var recoveryAttempts = 0
    private var isRecovering = false
    private var recoveryEpochState = SCKRecoveryEpochState()
    // Guards stream identity/generation/phase, output ownership, `_isCapturing`,
    // `recoveryAttempts`, `isRecovering`, and `recoveryEpochState` so the
    // buffer-stall watchdog (`checkWatchdog`, on `watchdogQueue`), the
    // `SCStreamDelegate` callback (on ScreenCaptureKit's delegate queue), and
    // the recovery block they spawn (on a `.userInitiated` global queue)
    // cannot race each other's guard-check-then-set of these fields — e.g.
    // both a buffer-stall and a `didStopWithError` callback observing
    // "not yet recovering" and both kicking off a recovery attempt. Official
    // stop paths also invalidate recovery while holding this same lock.
    private let captureStateLock = NSLock()
    private static let defaultCallbackTimeoutSeconds = 8
    private static let permissionPromptCallbackTimeoutSeconds = 120
    private static let defaultCallbackTimeout: DispatchTimeInterval = .seconds(defaultCallbackTimeoutSeconds)
    private static let permissionPromptCallbackTimeout: DispatchTimeInterval = .seconds(permissionPromptCallbackTimeoutSeconds)
    private let callbackTimeout: DispatchTimeInterval
    private let callbackTimeoutSeconds: Int
    private let testHooks: SCKAudioCaptureTestHooks
    private static let maxRecoveryAttempts = 1
    private static let bufferStallTimeoutSeconds: CFTimeInterval = 5
    private let watchdogQueue = DispatchQueue(label: "SCKAudioCapture.watchdog", qos: .utility)
    private var watchdogTimer: DispatchSourceTimer?
    private let watchdogLock = NSLock()
    private var _lastBufferTime: CFTimeInterval = CACurrentMediaTime()
    private var _hasReceivedFirstBuffer = false

    var diagnosticBackendName: String { "screen_capture_kit" }

    // Buffer statistics (thread-safe)
    private var _totalBuffers: Int = 0
    private var _buffersWithData: Int = 0
    private let statsLock = NSLock()

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

    // MARK: - Lifecycle

    func prepare() throws {
        try prepare(preservingRecoveryToken: nil)
    }

    private func prepare(preservingRecoveryToken recoveryToken: SCKRecoveryEpochState.Token?) throws {
        try validateRecoveryToken(recoveryToken)
        AppLogger.audioSystem.info("SCKAudioCapture: preparing ScreenCaptureKit audio stream")
        try stopCurrentStreamBeforePrepare(preservingRecoveryToken: recoveryToken)
        try validateRecoveryToken(recoveryToken)
        let prepareGeneration = incrementGeneration()

        // Fetch shareable content. On first use this can be held by the macOS
        // permission prompt, so it gets a longer timeout than normal callbacks.
        let semaphore = DispatchSemaphore(value: 0)
        var content: SCShareableContent?
        var fetchError: Error?

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { result, error in
            content = result
            fetchError = error
            semaphore.signal()
        }
        try Self.waitForCallback(
            semaphore,
            operation: "shareable content fetch",
            timeout: Self.permissionPromptCallbackTimeout,
            timeoutSeconds: Self.permissionPromptCallbackTimeoutSeconds
        )
        try validateRecoveryToken(recoveryToken)

        if let error = fetchError {
            AppLogger.audioSystem.error("SCKAudioCapture: failed to get shareable content", ["error": error.localizedDescription])
            throw error
        }

        guard let display = content?.displays.first else {
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

    private func start(
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
            publishHealthyIfCurrent(identity: streamIdentity, generation: startGeneration)
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

    private func stopSync(preservingRecoveryToken recoveryToken: SCKRecoveryEpochState.Token?) {
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

    private func incrementGeneration() -> UInt64 {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        _generation &+= 1
        return _generation
    }

    private func currentGeneration() -> UInt64 {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return _generation
    }

    private func currentStreamState() -> CurrentStreamState {
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

    private func shouldContinueRecovery(
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

    private func installPreparedStreamIfCurrent(
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
        guard _generation == generation,
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

    private func isCurrentCapturingStream(identity: ObjectIdentifier, generation: UInt64) -> Bool {
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
        _generation &+= 1

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

    private func activeFailureCallback(generation: UInt64) -> ((AVAudioPCMBuffer) -> Void)? {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        guard _isCapturing,
              streamPhase == .capturing,
              streamGeneration == generation else {
            return nil
        }
        return bufferCallback
    }

    private func isActiveCaptureGeneration(_ generation: UInt64) -> Bool {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return _isCapturing
            && streamPhase == .capturing
            && streamGeneration == generation
    }

    private func clearStreamStateLocked(
        expectedIdentity: ObjectIdentifier,
        expectedGeneration: UInt64
    ) -> Bool {
        guard streamGeneration == expectedGeneration,
              stream?.captureIdentity == expectedIdentity else {
            return false
        }
        testHooks.afterCleanupValidationWhileLocked?()
        _isCapturing = false
        isWaitingForTimedOutStopCallback = false
        stream = nil
        streamOutput = nil
        bufferCallback = nil
        _audioFormat = nil
        streamGeneration = nil
        streamPhase = .idle
        return true
    }

    private func finishCleanupSideEffects() {
        AppLogger.audioSystem.info("SCKAudioCapture: cleanup")
        logStats()
        stopWatchdog()
        resetStats()
        resetBufferWatchdogState()
    }

    private func cleanupIfCurrent(
        generation: UInt64,
        stream expectedStream: any SCKStreamControlling
    ) {
        captureStateLock.lock()
        let didCleanup = clearStreamStateLocked(
            expectedIdentity: expectedStream.captureIdentity,
            expectedGeneration: generation
        )
        captureStateLock.unlock()

        guard didCleanup else {
            AppLogger.audioSystem.info("SCKAudioCapture: skipping stale cleanup")
            return
        }
        finishCleanupSideEffects()
    }

    private func cleanupStreamReference(
        _ expectedStream: any SCKStreamControlling,
        generation: UInt64
    ) {
        cleanupIfCurrent(generation: generation, stream: expectedStream)
    }

    private func cleanupPreparedStreamReferenceIfCurrent(
        _ expectedStream: any SCKStreamControlling,
        generation: UInt64
    ) {
        captureStateLock.lock()
        let didCleanup: Bool
        if streamPhase == .prepared {
            didCleanup = clearStreamStateLocked(
                expectedIdentity: expectedStream.captureIdentity,
                expectedGeneration: generation
            )
        } else {
            didCleanup = false
        }
        captureStateLock.unlock()

        if didCleanup {
            finishCleanupSideEffects()
        }
    }

    private func stopStreamAndCleanupAfterFailedStartIfOwned(
        _ expectedStream: any SCKStreamControlling,
        generation: UInt64
    ) {
        var shouldRequestStop = false
        var didCleanupPreparedStream = false
        captureStateLock.lock()
        if streamGeneration == generation,
           stream?.captureIdentity == expectedStream.captureIdentity {
            switch streamPhase {
            case .starting, .capturing:
                _generation &+= 1
                _isCapturing = false
                streamPhase = .stopping
                shouldRequestStop = true
            case .prepared, .idle:
                didCleanupPreparedStream = clearStreamStateLocked(
                    expectedIdentity: expectedStream.captureIdentity,
                    expectedGeneration: generation
                )
            case .stopping, .stopTimedOut:
                break
            }
        }
        captureStateLock.unlock()

        if didCleanupPreparedStream {
            finishCleanupSideEffects()
        }
        guard shouldRequestStop else { return }
        if stopStreamSynchronously(expectedStream, cleanupAfterLateCallback: { [weak self, expectedStream] in
            self?.cleanupStreamReference(expectedStream, generation: generation)
        }) {
            cleanupStreamReference(expectedStream, generation: generation)
        } else {
            retainStreamReferenceAfterTimedOutStop(expectedStream, generation: generation)
        }
    }

    private func retainStreamReferenceAfterTimedOutStop(
        _ expectedStream: any SCKStreamControlling,
        generation: UInt64
    ) {
        captureStateLock.lock()
        guard streamGeneration == generation,
              stream?.captureIdentity == expectedStream.captureIdentity else {
            captureStateLock.unlock()
            AppLogger.audioSystem.info("SCKAudioCapture: skipping timed-out stop retention for replaced stream")
            return
        }
        _isCapturing = false
        isWaitingForTimedOutStopCallback = true
        streamPhase = .stopTimedOut
        captureStateLock.unlock()
        stopWatchdog()
        AppLogger.audioSystem.warning("SCKAudioCapture: keeping stream reference after stop timeout")
    }

    private func finishRecovery(_ token: SCKRecoveryEpochState.Token) {
        captureStateLock.lock()
        if recoveryEpochState.finish(token) {
            isRecovering = false
        }
        captureStateLock.unlock()
    }

    @discardableResult
    private func stopStreamSynchronously(
        _ stream: any SCKStreamControlling,
        cleanupAfterLateCallback: (() -> Void)? = nil
    ) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let callbackState = SCKStopCallbackState()
        stream.stopCapture { error in
            if let error = error {
                AppLogger.audioSystem.warning("SCKAudioCapture: stop error", ["error": error.localizedDescription])
            }
            let shouldCleanupLate = callbackState.complete()
            semaphore.signal()
            if shouldCleanupLate {
                AppLogger.audioSystem.info("SCKAudioCapture: running late stop callback cleanup")
                cleanupAfterLateCallback?()
            }
        }
        do {
            try Self.waitForCallback(
                semaphore,
                operation: "stop capture",
                timeout: callbackTimeout,
                timeoutSeconds: callbackTimeoutSeconds
            )
            return true
        } catch {
            guard callbackState.markTimedOutUnlessComplete() else {
                return true
            }
            AppLogger.audioSystem.warning("SCKAudioCapture: stop timed out", ["error": error.localizedDescription])
            return false
        }
    }

    private static func waitForCallback(
        _ semaphore: DispatchSemaphore,
        operation: String,
        timeout: DispatchTimeInterval,
        timeoutSeconds: Int
    ) throws {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            let error = SCKCaptureTimeoutError(operation: operation)
            AppLogger.audioSystem.error("SCKAudioCapture: callback timed out", [
                "operation": operation,
                "timeoutSeconds": "\(timeoutSeconds)"
            ])
            throw error
        }
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

    private func logStats() {
        statsLock.lock()
        let total = _totalBuffers
        let withData = _buffersWithData
        statsLock.unlock()
        AppLogger.audioSystem.info("SCKAudioCapture: buffer stats", [
            "total": "\(total)",
            "withData": "\(withData)"
        ])
    }

    private func resetStats() {
        statsLock.lock()
        _totalBuffers = 0
        _buffersWithData = 0
        statsLock.unlock()
    }

    private func publishErrorMessage(_ message: String?) {
        if Thread.isMainThread {
            errorMessage = message
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = message
            }
        }
    }

    private func publishHealthyIfCurrent(identity: ObjectIdentifier, generation: UInt64) {
        let publish = { [weak self] in
            guard let self,
                  self.isCurrentCapturingStream(identity: identity, generation: generation) else {
                return
            }
            self.errorMessage = nil
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }

    private func resetBufferWatchdogState() {
        watchdogLock.lock()
        _lastBufferTime = CACurrentMediaTime()
        _hasReceivedFirstBuffer = false
        watchdogLock.unlock()
    }

    private func markBufferReceived() {
        watchdogLock.lock()
        _lastBufferTime = CACurrentMediaTime()
        _hasReceivedFirstBuffer = true
        watchdogLock.unlock()
    }

    private func startWatchdog(generation: UInt64) {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        let interval = DispatchTimeInterval.milliseconds(Int(Self.bufferStallTimeoutSeconds * 1000))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.checkWatchdog(generation: generation)
        }
        watchdogLock.lock()
        watchdogTimer = timer
        watchdogLock.unlock()
        timer.resume()
    }

    private func stopWatchdog() {
        watchdogLock.lock()
        let timer = watchdogTimer
        watchdogTimer = nil
        watchdogLock.unlock()
        timer?.cancel()
    }

    private func checkWatchdog(generation: UInt64) {
        guard isActiveCaptureGeneration(generation) else { return }
        watchdogLock.lock()
        let hasReceivedFirstBuffer = _hasReceivedFirstBuffer
        let elapsed = CACurrentMediaTime() - _lastBufferTime
        watchdogLock.unlock()

        guard hasReceivedFirstBuffer, elapsed >= Self.bufferStallTimeoutSeconds else { return }
        AppLogger.audioSystem.error("SCKAudioCapture: buffer watchdog timed out", [
            "elapsedSeconds": String(format: "%.1f", elapsed)
        ])
        handleMidRecordingFailure(
            "System audio failed - ScreenCaptureKit stopped sending audio buffers.",
            generation: generation,
            attemptRestart: true
        )
    }

    private func handleMidRecordingFailure(
        _ message: String,
        generation: UInt64,
        attemptRestart: Bool
    ) {
        guard isActiveCaptureGeneration(generation) else { return }
        guard attemptRestart, let callback = activeFailureCallback(generation: generation) else {
            publishErrorMessage(message)
            return
        }

        // Atomically check-and-set recovery state so concurrent failure
        // callbacks cannot both start recovery, and an official stop cannot
        // slip between the active-capture check and token creation.
        var recoveryToken: SCKRecoveryEpochState.Token?
        var recoveryAttempt = 0
        var exhaustedRecovery = false
        captureStateLock.lock()
        if _isCapturing,
           streamPhase == .capturing,
           streamGeneration == generation,
           recoveryEpochState.acceptsRecovery,
           !isRecovering {
            if recoveryAttempts < Self.maxRecoveryAttempts {
                recoveryAttempts += 1
                isRecovering = true
                recoveryAttempt = recoveryAttempts
                recoveryToken = recoveryEpochState.begin()
            } else {
                exhaustedRecovery = true
            }
        }
        captureStateLock.unlock()

        guard let recoveryToken else {
            if exhaustedRecovery {
                publishErrorMessage(message)
            }
            return
        }
        publishErrorMessage("System audio reconnecting after capture interruption.")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { self.finishRecovery(recoveryToken) }
            do {
                AppLogger.audioSystem.info("SCKAudioCapture: attempting stream recovery", [
                    "attempt": "\(recoveryAttempt)"
                ])

                guard self.shouldContinueRecovery(recoveryToken, at: "before cleanup") else { return }
                self.stopSync(preservingRecoveryToken: recoveryToken)
                guard self.shouldContinueRecovery(recoveryToken, at: "after cleanup") else { return }

                guard self.shouldContinueRecovery(recoveryToken, at: "before prepare") else { return }
                try self.prepare(preservingRecoveryToken: recoveryToken)
                guard self.shouldContinueRecovery(recoveryToken, at: "after prepare") else { return }

                guard self.shouldContinueRecovery(recoveryToken, at: "before start") else { return }
                try self.start(bufferCallback: callback, recoveryToken: recoveryToken)
                guard self.shouldContinueRecovery(recoveryToken, at: "after start") else { return }
                AppLogger.audioSystem.info("SCKAudioCapture: stream recovery succeeded")
            } catch is SCKRecoveryCancelledError {
                AppLogger.audioSystem.info("SCKAudioCapture: recovery stopped after cancellation")
            } catch {
                guard self.shouldContinueRecovery(recoveryToken, at: "failure") else { return }
                AppLogger.audioSystem.error("SCKAudioCapture: stream recovery failed", [
                    "error": error.localizedDescription
                ])
                self.publishErrorMessage("System audio failed - ScreenCaptureKit could not restart audio capture.")
            }
        }
    }

    // Internal deterministic seams for the package's hostile interleaving
    // tests. Production construction still uses real `SCStream` instances.
    @discardableResult
    func installPreparedStreamForTesting(_ preparedStream: any SCKStreamControlling) -> UInt64 {
        let generation = incrementGeneration()
        precondition(
            installPreparedStreamIfCurrent(
                preparedStream,
                audioFormat: nil,
                recoveryToken: nil,
                generation: generation
            )
        )
        return generation
    }

    @discardableResult
    func replacePreparedStreamForTesting(_ preparedStream: any SCKStreamControlling) -> UInt64 {
        captureStateLock.lock()
        _generation &+= 1
        let generation = _generation
        stream = preparedStream
        streamOutput = nil
        bufferCallback = nil
        _audioFormat = nil
        streamGeneration = generation
        streamPhase = .prepared
        _isCapturing = false
        isWaitingForTimedOutStopCallback = false
        captureStateLock.unlock()
        return generation
    }

    func cleanupStreamForTesting(
        _ expectedStream: any SCKStreamControlling,
        generation: UInt64
    ) {
        cleanupIfCurrent(generation: generation, stream: expectedStream)
    }

    func stateSnapshotForTesting() -> SCKAudioCaptureStateSnapshot {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return SCKAudioCaptureStateSnapshot(
            streamIdentity: stream?.captureIdentity,
            generation: streamGeneration,
            phase: streamPhase.rawValue,
            isCapturing: _isCapturing,
            isWaitingForTimedOutStopCallback: isWaitingForTimedOutStopCallback,
            recoveryAttempts: recoveryAttempts
        )
    }
}

// MARK: - SCStream Audio Output

/// Receives audio sample buffers from SCStream and converts them to AVAudioPCMBuffer.
@available(macOS 26.0, *)
private final class SCKAudioStreamOutput: NSObject, SCStreamOutput {
    private let onBuffer: (AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let pcmBuffer = Self.createPCMBuffer(from: sampleBuffer) else { return }
        onBuffer(pcmBuffer)
    }

    /// Convert CMSampleBuffer (ScreenCaptureKit's delivery format) to AVAudioPCMBuffer
    /// (the format the rest of the pipeline expects).
    ///
    /// Allocates a new buffer and copies the audio data — the CMSampleBuffer's backing
    /// memory is only valid during this callback, so the copy is required.
    static func createPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        guard let format = AVAudioFormat(streamDescription: asbd) else { return nil }

        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numFrames > 0 else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(numFrames)
        ) else { return nil }

        pcmBuffer.frameLength = AVAudioFrameCount(numFrames)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numFrames),
            into: pcmBuffer.mutableAudioBufferList
        )

        guard status == noErr else { return nil }
        return pcmBuffer
    }
}

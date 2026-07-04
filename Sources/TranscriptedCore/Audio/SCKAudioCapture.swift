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
final class SCKAudioCapture: NSObject, ObservableObject, SystemAudioCaptureEngine, SCStreamDelegate, @unchecked Sendable {
    @Published var errorMessage: String?

    private var stream: SCStream?
    private var streamOutput: SCKAudioStreamOutput?
    private var _audioFormat: AVAudioFormat?
    private var _isCapturing = false
    private var bufferCallback: ((AVAudioPCMBuffer) -> Void)?
    private var _generation: UInt64 = 0
    private let generationLock = NSLock()
    private var isWaitingForTimedOutStopCallback = false
    private var recoveryAttempts = 0
    private var isRecovering = false
    private static let callbackTimeoutSeconds = 8
    private static let permissionPromptCallbackTimeoutSeconds = 120
    private static let callbackTimeout: DispatchTimeInterval = .seconds(callbackTimeoutSeconds)
    private static let permissionPromptCallbackTimeout: DispatchTimeInterval = .seconds(permissionPromptCallbackTimeoutSeconds)
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

    var audioFormat: AVAudioFormat? { _audioFormat }
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
        AppLogger.audioSystem.info("SCKAudioCapture: preparing ScreenCaptureKit audio stream")
        try stopCurrentStreamBeforePrepare()
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
            stopStreamSynchronously(preparedStream)
            throw AudioCaptureStaleSessionError()
        }
        _audioFormat = audioFormat
        stream = preparedStream

        AppLogger.audioSystem.info("SCKAudioCapture: stream prepared", [
            "sampleRate": "48000",
            "channels": "2"
        ])
    }

    func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !isWaitingForTimedOutStopCallback else {
            AppLogger.audioSystem.warning("SCKAudioCapture: refusing to start stream while previous stop is still pending")
            throw SCKCaptureTimeoutError(operation: "previous stop cleanup")
        }
        guard !_isCapturing else {
            AppLogger.audioSystem.warning("SCKAudioCapture: refusing to start stream because capture is already active")
            throw "SCKAudioCapture: capture already active"
        }
        guard let stream = stream else {
            AppLogger.audioSystem.info("SCKAudioCapture: auto-preparing in start()")
            try prepare()
            guard self.stream != nil else { throw "SCKAudioCapture: prepare failed silently" }
            return try start(bufferCallback: bufferCallback)
        }
        let startGeneration = currentGeneration()

        self.bufferCallback = bufferCallback
        resetBufferWatchdogState()
        if !isRecovering {
            recoveryAttempts = 0
        }
        publishErrorMessage(nil)

        // Output handler converts CMSampleBuffer → AVAudioPCMBuffer
        let output = SCKAudioStreamOutput { [weak self] buffer in
            guard let self = self else { return }
            guard self.currentGeneration() == startGeneration else { return }
            self.statsLock.lock()
            self._totalBuffers += 1
            self._buffersWithData += 1
            self.statsLock.unlock()
            self.markBufferReceived()
            bufferCallback(buffer)
        }
        self.streamOutput = output

        let queue = DispatchQueue(label: "SCKAudioCapture.output", qos: .userInitiated)
        var didRequestStart = false
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)

            // Start capture — synchronous wait since we're on a background thread.
            let semaphore = DispatchSemaphore(value: 0)
            var startError: Error?
            didRequestStart = true
            stream.startCapture { error in
                startError = error
                semaphore.signal()
            }
            try Self.waitForCallback(semaphore, operation: "start capture")

            if let error = startError {
                throw error
            }

            guard currentGeneration() == startGeneration, self.stream === stream else {
                throw AudioCaptureStaleSessionError()
            }
            _isCapturing = true
            startWatchdog(generation: startGeneration)
            AppLogger.audioSystem.info("SCKAudioCapture: now capturing system audio")
        } catch {
            AppLogger.audioSystem.error("SCKAudioCapture: start failed", ["error": error.localizedDescription])
            if didRequestStart {
                invalidateGenerationIfCurrent(startGeneration)
                stopStreamAndCleanupIfConfirmed(stream)
            } else {
                cleanupStreamReference(stream)
            }
            publishErrorMessage(error.localizedDescription)
            throw error
        }
    }

    func stop() {
        guard let stream = stream else { return }
        let stopGeneration = currentGeneration()
        guard _isCapturing else {
            cleanupIfCurrent(generation: stopGeneration, stream: stream)
            return
        }

        _isCapturing = false
        stopWatchdog()
        stream.stopCapture { [weak self, stream] error in
            if let error = error {
                AppLogger.audioSystem.warning("SCKAudioCapture: stop error", ["error": error.localizedDescription])
            }
            self?.cleanupIfCurrent(generation: stopGeneration, stream: stream)
        }
    }

    func stopSync() {
        guard let stream = stream else { return }
        guard !isWaitingForTimedOutStopCallback else {
            AppLogger.audioSystem.warning("SCKAudioCapture: previous stop still pending")
            return
        }
        let stopGeneration = currentGeneration()
        guard _isCapturing else {
            cleanupIfCurrent(generation: stopGeneration, stream: stream)
            return
        }

        _isCapturing = false
        stopWatchdog()
        if stopStreamSynchronously(stream, cleanupAfterLateCallback: { [weak self, stream] in
            self?.cleanupIfCurrent(generation: stopGeneration, stream: stream)
        }) {
            cleanupIfCurrent(generation: stopGeneration, stream: stream)
        } else {
            retainStreamReferenceAfterTimedOutStop(stream)
        }
    }

    private func stopCurrentStreamBeforePrepare() throws {
        guard !isWaitingForTimedOutStopCallback else {
            AppLogger.audioSystem.warning("SCKAudioCapture: refusing to prepare new stream while previous stop is still pending")
            throw SCKCaptureTimeoutError(operation: "previous stop cleanup")
        }

        stopSync()

        guard !isWaitingForTimedOutStopCallback, stream == nil else {
            AppLogger.audioSystem.warning("SCKAudioCapture: refusing to prepare new stream because previous stream is still stopping")
            throw SCKCaptureTimeoutError(operation: "previous stop cleanup")
        }
    }

    private func incrementGeneration() -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        _generation &+= 1
        return _generation
    }

    private func currentGeneration() -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return _generation
    }

    private func invalidateGenerationIfCurrent(_ generation: UInt64) {
        generationLock.lock()
        defer { generationLock.unlock() }
        if _generation == generation {
            _generation &+= 1
        }
    }

    private func cleanupIfCurrent(generation: UInt64, stream expectedStream: SCStream) {
        guard currentGeneration() == generation,
              let currentStream = stream,
              currentStream === expectedStream else {
            AppLogger.audioSystem.info("SCKAudioCapture: skipping stale cleanup")
            return
        }
        cleanup()
    }

    private func cleanupStreamReference(_ expectedStream: SCStream) {
        guard let currentStream = stream,
              currentStream === expectedStream else {
            AppLogger.audioSystem.info("SCKAudioCapture: skipping cleanup for replaced stream")
            return
        }
        cleanup()
    }

    private func stopStreamAndCleanupIfConfirmed(_ expectedStream: SCStream) {
        if stopStreamSynchronously(expectedStream, cleanupAfterLateCallback: { [weak self, expectedStream] in
            self?.cleanupStreamReference(expectedStream)
        }) {
            cleanupStreamReference(expectedStream)
        } else {
            retainStreamReferenceAfterTimedOutStop(expectedStream)
        }
    }

    private func retainStreamReferenceAfterTimedOutStop(_ expectedStream: SCStream) {
        guard let currentStream = stream,
              currentStream === expectedStream else {
            AppLogger.audioSystem.info("SCKAudioCapture: skipping timed-out stop retention for replaced stream")
            return
        }

        _isCapturing = true
        isWaitingForTimedOutStopCallback = true
        startWatchdog(generation: currentGeneration())
        AppLogger.audioSystem.warning("SCKAudioCapture: keeping stream reference after stop timeout")
    }

    @discardableResult
    private func stopStreamSynchronously(
        _ stream: SCStream,
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
            try Self.waitForCallback(semaphore, operation: "stop capture")
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
        timeout: DispatchTimeInterval = callbackTimeout,
        timeoutSeconds: Int = callbackTimeoutSeconds
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

    private func cleanup() {
        AppLogger.audioSystem.info("SCKAudioCapture: cleanup")
        logStats()
        _isCapturing = false
        isWaitingForTimedOutStopCallback = false
        stopWatchdog()
        stream = nil
        streamOutput = nil
        bufferCallback = nil
        _audioFormat = nil
        resetStats()
        resetBufferWatchdogState()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppLogger.audioSystem.error("SCKAudioCapture: stream stopped with error", [
            "error": error.localizedDescription
        ])
        handleMidRecordingFailure(
            "System audio failed - ScreenCaptureKit stopped delivering audio.",
            generation: currentGeneration(),
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
        guard currentGeneration() == generation, _isCapturing else { return }
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
        guard currentGeneration() == generation, _isCapturing else { return }
        publishErrorMessage(message)
        guard attemptRestart,
              recoveryAttempts < Self.maxRecoveryAttempts,
              !isRecovering,
              let callback = bufferCallback else {
            return
        }

        recoveryAttempts += 1
        isRecovering = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { self.isRecovering = false }
            do {
                AppLogger.audioSystem.info("SCKAudioCapture: attempting stream recovery", [
                    "attempt": "\(self.recoveryAttempts)"
                ])
                self.stopSync()
                try self.prepare()
                try self.start(bufferCallback: callback)
                AppLogger.audioSystem.info("SCKAudioCapture: stream recovery succeeded")
            } catch {
                AppLogger.audioSystem.error("SCKAudioCapture: stream recovery failed", [
                    "error": error.localizedDescription
                ])
                self.publishErrorMessage("System audio failed - ScreenCaptureKit could not restart audio capture.")
            }
        }
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

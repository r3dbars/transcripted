import AVFoundation
import Combine
import CoreMedia
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
final class SCKAudioCapture: ObservableObject, SystemAudioCaptureEngine, @unchecked Sendable {
    @Published var errorMessage: String?

    private var stream: SCStream?
    private var streamOutput: SCKAudioStreamOutput?
    private var _audioFormat: AVAudioFormat?
    private var _isCapturing = false
    private var bufferCallback: ((AVAudioPCMBuffer) -> Void)?

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

        // Fetch shareable content — triggers the system permission dialog on first use.
        // Called from a background thread (AudioFileManager dispatches to .userInitiated),
        // so the semaphore won't deadlock.
        let semaphore = DispatchSemaphore(value: 0)
        var content: SCShareableContent?
        var fetchError: Error?

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { result, error in
            content = result
            fetchError = error
            semaphore.signal()
        }
        semaphore.wait()

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

        // Pre-create the format the WAV file will use. ScreenCaptureKit delivers
        // float32 non-interleaved audio matching the configured rate/channels.
        _audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )

        stream = SCStream(filter: filter, configuration: config, delegate: nil)

        AppLogger.audioSystem.info("SCKAudioCapture: stream prepared", [
            "sampleRate": "48000",
            "channels": "2"
        ])
    }

    func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard let stream = stream else {
            AppLogger.audioSystem.info("SCKAudioCapture: auto-preparing in start()")
            try prepare()
            guard self.stream != nil else { throw "SCKAudioCapture: prepare failed silently" }
            return try start(bufferCallback: bufferCallback)
        }

        self.bufferCallback = bufferCallback
        errorMessage = nil

        // Output handler converts CMSampleBuffer → AVAudioPCMBuffer
        let output = SCKAudioStreamOutput { [weak self] buffer in
            guard let self = self else { return }
            self.statsLock.lock()
            self._totalBuffers += 1
            self._buffersWithData += 1
            self.statsLock.unlock()
            bufferCallback(buffer)
        }
        self.streamOutput = output

        let queue = DispatchQueue(label: "SCKAudioCapture.output", qos: .userInitiated)
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)

            // Start capture — synchronous wait since we're on a background thread.
            let semaphore = DispatchSemaphore(value: 0)
            var startError: Error?
            stream.startCapture { error in
                startError = error
                semaphore.signal()
            }
            semaphore.wait()

            if let error = startError {
                throw error
            }

            _isCapturing = true
            AppLogger.audioSystem.info("SCKAudioCapture: now capturing system audio")
        } catch {
            AppLogger.audioSystem.error("SCKAudioCapture: start failed", ["error": error.localizedDescription])
            cleanup()
            DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            throw error
        }
    }

    func stop() {
        guard let stream = stream else { return }
        guard _isCapturing else {
            cleanup()
            return
        }

        _isCapturing = false
        stream.stopCapture { [weak self] error in
            if let error = error {
                AppLogger.audioSystem.warning("SCKAudioCapture: stop error", ["error": error.localizedDescription])
            }
            self?.cleanup()
        }
    }

    func stopSync() {
        guard let stream = stream else { return }
        guard _isCapturing else {
            cleanup()
            return
        }

        _isCapturing = false
        let semaphore = DispatchSemaphore(value: 0)
        stream.stopCapture { _ in
            semaphore.signal()
        }
        semaphore.wait()
        cleanup()
    }

    private func cleanup() {
        AppLogger.audioSystem.info("SCKAudioCapture: cleanup")
        logStats()
        _isCapturing = false
        stream = nil
        streamOutput = nil
        bufferCallback = nil
        _audioFormat = nil
        resetStats()
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

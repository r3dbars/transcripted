import Foundation
import Darwin
@preconcurrency import AVFoundation
import ScreenCaptureKit

enum SystemAudioCaptureFailureCopy {
    static func isExplicitPermissionDenial(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain
            && nsError.code == SCStreamError.Code.userDeclined.rawValue
    }

    static func message(for error: Error) -> String {
        if isExplicitPermissionDenial(error) {
            return "System Audio Recording is off. Turn it on for Transcripted in System Settings, then try again."
        }

        return "System audio couldn't start. Try recording again. If it keeps happening, quit and reopen Transcripted."
    }
}

/// Serializes start and stop for one system-audio capture attempt. A stop that
/// arrives during `prepare()` marks the attempt cancelled; a stop that races
/// `start()` waits and then tears it down.
final class SystemAudioCaptureStartAttempt: @unchecked Sendable {
    let capture: any SystemAudioCaptureEngine & Sendable
    private let lifecycleLock = NSLock()
    private var cancelled = false
    private var startRequested = false
    private var draining = false
    private var observedSignal = false
    private var finalizationFailed = false
    private var stopOwnedFileURL: URL?
    private var setupDiscardedFileURL: URL?
    private let beforeFinishForTesting: (() -> Void)?
    var hasFinalizationFailure: Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return finalizationFailed
    }
    var hasObservedSignal: Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return observedSignal
    }
    func observeSignal(_ buffer: AVAudioPCMBuffer) {
        guard !hasObservedSignal else { return }
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return }
        for item in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = item.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<(Int(item.mDataByteSize) / MemoryLayout<Float>.size) {
                if samples[index].isFinite && samples[index] != 0 {
                    lifecycleLock.lock(); observedSignal = true; lifecycleLock.unlock()
                    return
                }
            }
        }
    }
    let tailAdmission = PCMBufferBackpressureGate(byteLimit: 8 * 1_024 * 1_024)
    var isDraining: Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return draining
    }

    init(capture: any SystemAudioCaptureEngine & Sendable, beforeFinishForTesting: (() -> Void)? = nil) {
        self.capture = capture
        self.beforeFinishForTesting = beforeFinishForTesting
    }

    func prepare() throws {
        try capture.prepare()
        // prepare() can block on ScreenCaptureKit. Honor a cancel that
        // arrived while it ran so start() never begins a doomed stream.
        lifecycleLock.lock()
        let wasCancelled = cancelled
        lifecycleLock.unlock()
        if wasCancelled {
            capture.stopSync()
        }
    }

    @discardableResult
    func startIfNotCancelled(
        bufferCallback: @escaping (AVAudioPCMBuffer) -> Void
    ) throws -> Bool {
        lifecycleLock.lock()
        guard !cancelled else {
            lifecycleLock.unlock()
            return false
        }
        startRequested = true
        lifecycleLock.unlock()

        // Do not hold lifecycleLock across start() — cancel() shares that
        // lock and must not block behind a ScreenCaptureKit start callback.
        try capture.start(bufferCallback: bufferCallback)

        lifecycleLock.lock()
        let wasCancelled = cancelled
        lifecycleLock.unlock()
        if wasCancelled {
            capture.stopSync()
            return false
        }
        return true
    }

    func cancel() {
        lifecycleLock.lock()
        cancelled = true
        draining = false
        tailAdmission.close(generation: 1)
        lifecycleLock.unlock()
        capture.stopSync()
    }

    func finishAndDrain() {
        lifecycleLock.lock()
        if !cancelled {
            cancelled = true
            if !draining {
                draining = true
                tailAdmission.begin(generation: 1)
            }
        }
        lifecycleLock.unlock()
        // Every finisher fences and snapshots health. A duplicate must not
        // convert FINISH into CANCEL before the first caller enters HAL.
        // No caller mutex spans this queue hop (subscribers can reenter).
        beforeFinishForTesting?()
        capture.finishAndDrain()
        let backendFailed = capture.bufferSuccessRate == 0
        lifecycleLock.lock()
        finalizationFailed = finalizationFailed || backendFailed
        draining = false
        tailAdmission.close(generation: 1)
        lifecycleLock.unlock()
    }

    /// Arm before the host advances its generation, closing the consumer-timer
    /// race between UI Stop and asynchronous producer shutdown.
    func beginFinishing() {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard !cancelled, !draining else { return }
        draining = true
        tailAdmission.begin(generation: 1)
    }

    /// Stop claims the WAV it resolved before handing it to the pipeline. Nil
    /// when the setup already committed to discarding that file, even if it
    /// is still on disk. Resolve outside this lock: it can wait on the
    /// journal queue, and the capture consumer takes this lock per buffer.
    func handOffRecordedFileToStop(_ resolvedURL: URL?) -> URL? {
        guard let url = resolvedURL else { return nil }
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        if let discarded = setupDiscardedFileURL,
           discarded.standardizedFileURL == url.standardizedFileURL {
            return nil
        }
        stopOwnedFileURL = url
        return url
    }

    /// An abandoned setup asks before it closes, cancels or deletes. False
    /// means Stop already handed this file off, so Stop's finish-and-drain
    /// owns the writer and the file; cancelling would drop the tail and
    /// deleting would leave the pipeline a missing system track.
    func mayDiscardAbandonedSetupFile(_ fileURL: URL) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        if let owned = stopOwnedFileURL,
           owned.standardizedFileURL == fileURL.standardizedFileURL {
            return false
        }
        setupDiscardedFileURL = fileURL
        return true
    }

    func enqueueFinishingBuffer(_ buffer: AVAudioPCMBuffer, writer: AVAudioFile,
                                queue: DispatchQueue, onError: @escaping (Error) -> Void) {
        guard isDraining else { return }
        let bytes = PCMBufferBackpressureGate.retainedByteCount(for: buffer)
        switch tailAdmission.admit(bytes: bytes, generation: 1) {
        case .accepted: break
        case .firstOverflow:
            lifecycleLock.lock(); finalizationFailed = true; lifecycleLock.unlock()
            onError(NSError(domain: "SystemAudioTail", code: 1, userInfo: [NSLocalizedDescriptionKey: "System audio finalization exceeded its bounded buffer limit."]))
            return
        case .closed: return
        }
        // The protocol also permits borrowed buffers. The finishing path owns
        // its samples even for injected or future backends, not only Core Audio.
        guard let owned = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            tailAdmission.release(bytes: bytes)
            lifecycleLock.lock(); finalizationFailed = true; lifecycleLock.unlock()
            onError(NSError(domain: "SystemAudioTail", code: 2))
            return
        }
        owned.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
        for index in 0..<source.count {
            memcpy(target[index].mData!, source[index].mData!, Int(source[index].mDataByteSize))
        }
        queue.async {
            defer { self.tailAdmission.release(bytes: bytes) }
            do { try writer.write(from: owned) } catch {
                self.lifecycleLock.lock(); self.finalizationFailed = true; self.lifecycleLock.unlock()
                onError(error)
            }
        }
    }
}

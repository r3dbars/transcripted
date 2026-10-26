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

struct SCKRecoveryCancelledError: LocalizedError {
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

@available(macOS 26.0, *)
struct SCKCaptureTimeoutError: LocalizedError {
    let operation: String

    var errorDescription: String? {
        "ScreenCaptureKit \(operation) timed out."
    }
}

@available(macOS 26.0, *)
final class SCKStopCallbackState {
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
final class SCKShareableContentFetchState: @unchecked Sendable {
    private let lock = NSLock()
    private var content: SCShareableContent?
    private var fetchError: Error?
    let semaphore = DispatchSemaphore(value: 0)

    func complete(content: SCShareableContent?, error: Error?) {
        lock.lock()
        self.content = content
        self.fetchError = error
        lock.unlock()
        semaphore.signal()
    }

    func result() -> (content: SCShareableContent?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (content, fetchError)
    }
}

final class SCKStartCallbackState: @unchecked Sendable {
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


// MARK: - SCStream Audio Output

/// Receives audio sample buffers from SCStream and converts them to AVAudioPCMBuffer.
@available(macOS 26.0, *)
final class SCKAudioStreamOutput: NSObject, SCStreamOutput {
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

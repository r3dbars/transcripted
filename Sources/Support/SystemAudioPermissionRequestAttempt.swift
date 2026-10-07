import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio
import Combine
import EventKit
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// Bounds one callback-driven System Audio Recording permission request.
///
/// Audio services have no completion guarantee for every TCC or daemon state.
/// This main-actor gate makes timeout, caller cancellation, and real callbacks
/// race through one terminal result so a late callback cannot resume a checked
/// continuation twice or revive a finished request.
@MainActor
final class SystemAudioPermissionRequestAttempt {
    typealias ProbeResult = TranscriptedPermissionAccess.SystemAudioPermissionProbeResult
    typealias Completion = (ProbeResult) -> Void
    typealias TimeoutScheduler = @MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void

    private let scheduleTimeout: TimeoutScheduler
    private let onTimeout: () -> Void
    private let onResolved: (ProbeResult) -> Void
    private var continuation: CheckedContinuation<ProbeResult, Never>?
    private var cancelTimeout: (() -> Void)?
    private var cleanup: (() -> Void)?
    private var result: ProbeResult?

    init(
        timeoutNanoseconds: UInt64 = TranscriptedConstants.systemAudioPermissionRequestTimeout,
        scheduleTimeout: TimeoutScheduler? = nil,
        onTimeout: @escaping () -> Void = {},
        onResolved: @escaping (ProbeResult) -> Void = { _ in }
    ) {
        self.scheduleTimeout = scheduleTimeout ?? { action in
            Self.liveTimeoutScheduler(action, timeoutNanoseconds: timeoutNanoseconds)
        }
        self.onTimeout = onTimeout
        self.onResolved = onResolved
    }

    func awaitResult(
        start: @escaping (@escaping Completion) -> Void,
        cleanup: @escaping () -> Void
    ) async -> ProbeResult {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .indeterminate(.cancelled))
                    return
                }
                if let result {
                    continuation.resume(returning: result)
                    return
                }

                self.continuation = continuation
                self.cleanup = cleanup
                self.cancelTimeout = scheduleTimeout { [weak self] in
                    self?.timeout()
                }
                start { [weak self] granted in
                    Task { @MainActor [weak self] in
                        self?.finish(granted)
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.finish(.indeterminate(.cancelled))
            }
        })
    }

    private func timeout() {
        guard result == nil else { return }
        onTimeout()
        finish(.indeterminate(.timedOut))
    }

    private func finish(_ result: ProbeResult) {
        guard self.result == nil else { return }
        self.result = result

        let continuation = continuation
        self.continuation = nil
        let cancelTimeout = cancelTimeout
        self.cancelTimeout = nil
        let cleanup = cleanup
        self.cleanup = nil

        cancelTimeout?()
        cleanup?()
        onResolved(result)
        continuation?.resume(returning: result)
    }

    private static func liveTimeoutScheduler(
        _ action: @escaping @MainActor () -> Void,
        timeoutNanoseconds: UInt64
    ) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            action()
        }
        return {
            task.cancel()
        }
    }
}

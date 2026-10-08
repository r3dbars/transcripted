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

@available(macOS 26.0, *)
@MainActor
final class SystemAudioPermissionRequester {
    typealias ProbeResult = TranscriptedPermissionAccess.SystemAudioPermissionProbeResult
    typealias ProbeStage = TranscriptedPermissionAccess.SystemAudioPermissionProbeStage

    private let worker: SystemAudioPermissionProbeWorker
    private var completion: ((ProbeResult) -> Void)?
    private var backendErrorSubscription: AnyCancellable?

    init(
        prepare: @escaping () throws -> Void,
        start: @escaping (@escaping (SystemAudioPermissionSampleEvidence) -> Void) throws -> Void,
        stop: @escaping () -> Void,
        silenceObservationDelay: TimeInterval = 2
    ) {
        worker = SystemAudioPermissionProbeWorker(prepare: prepare, start: start, stop: stop, silenceObservationDelay: silenceObservationDelay)
    }

#if !canImport(TranscriptedCore)
    convenience init() {
        // Fast tests inject the backend; a missing backend never grants access.
        self.init(prepare: { throw NSError(domain: "SystemAudioPermissionProbe", code: 1) },
                  start: { _ in }, stop: {})
    }
#endif

    func observeBackendErrors(_ publisher: AnyPublisher<String?, Never>) {
        backendErrorSubscription = publisher.sink { [weak self] message in
            Task { @MainActor [weak self] in self?.handleBackendError(message) }
        }
    }

    func requestAccess(completion: @escaping (ProbeResult) -> Void) {
        self.completion = completion

        worker.begin { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finish(result)
            }
        }
    }

    func cancel() {
        completion = nil
        backendErrorSubscription = nil
        worker.cancel()
    }

    func handleBackendError(_ message: String?) {
        // Match the backend's terminal-failure vocabulary, not its temporary
        // reconnecting notice. An audio-service failure is never TCC denial.
        guard message?.hasPrefix("System audio failed") == true else { return }
        finish(.indeterminate(.startCapture))
    }

    private func finish(_ result: ProbeResult) {
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}

/// Serializes Core Audio setup/teardown away from the main actor. Cancellation
/// is remembered even while prepare is blocked, so its eventual return cannot
/// start a stale recording. Only signal presence is checked; no audio is saved
/// or sent anywhere. Core Audio can return silent frames when access is off.
private final class SystemAudioPermissionProbeWorker: @unchecked Sendable {
    typealias ProbeResult = TranscriptedPermissionAccess.SystemAudioPermissionProbeResult
    private let queue = DispatchQueue(label: "Transcripted.SystemAudioPermission")
    private let lock = NSLock()
    private var cancelled = false
    private var resolved = false
    private let prepare: () throws -> Void
    private let start: (@escaping (SystemAudioPermissionSampleEvidence) -> Void) throws -> Void
    private let stop: () -> Void
    private let silenceObservationDelay: TimeInterval
    private var silenceTimerScheduled = false // queue-owned

    init(prepare: @escaping () throws -> Void,
         start: @escaping (@escaping (SystemAudioPermissionSampleEvidence) -> Void) throws -> Void,
         stop: @escaping () -> Void,
         silenceObservationDelay: TimeInterval) {
        self.prepare = prepare
        self.start = start
        self.stop = stop
        self.silenceObservationDelay = silenceObservationDelay
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func begin(completion: @escaping (ProbeResult) -> Void) {
        queue.async { [self] in
            guard !isCancelled else { return }
            do {
                try prepare()
            } catch {
                resolve(SystemAudioPermissionProbeClassifier.result(for: error, stage: .prepareCapture), completion)
                return
            }
            guard !isCancelled else { return }
            do {
                try start { [weak self] evidence in
                    // The engine delivers owned buffers off its real-time I/O
                    // callback. Silence is inconclusive, never an explicit denial.
                    guard let self else { return }
                    self.queue.async { [self] in
                        guard !self.isCancelled else { return }
                        switch evidence {
                        case .signal:
                            self.resolve(.granted, completion)
                        case .silentFrames:
                            guard !self.silenceTimerScheduled else { return }
                            self.silenceTimerScheduled = true
                            self.queue.asyncAfter(deadline: .now() + self.silenceObservationDelay) { [weak self] in
                                self?.resolve(.indeterminate(.silentAudio), completion)
                            }
                        case .noValidFrames:
                            break
                        }
                    }
                }
            } catch {
                resolve(SystemAudioPermissionProbeClassifier.result(for: error, stage: .startCapture), completion)
            }
        }
    }

    private func resolve(_ result: ProbeResult, _ completion: (ProbeResult) -> Void) {
        lock.lock()
        let shouldResolve = !cancelled && !resolved
        resolved = true
        lock.unlock()
        if shouldResolve { completion(result) }
    }

    func cancel() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        lock.unlock()
        guard !wasCancelled else { return }
        // Runs after in-flight setup, even if the caller already timed out.
        queue.async { [self] in stop() }
    }
}

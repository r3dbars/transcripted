import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio
import Combine
import EventKit
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

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

    convenience init() {
#if canImport(TranscriptedCore)
        let capture = CoreAudioSystemAudioCapture()
        self.init(
            prepare: { try capture.prepare() },
            start: { receivedSignal in
                try capture.start { buffer in
                    receivedSignal(SystemAudioPermissionProbeClassifier.sampleEvidence(buffer))
                }
            },
            stop: { capture.stopSync() }
        )
        backendErrorSubscription = capture.errorMessagePublisher.sink { [weak self] message in
            Task { @MainActor [weak self] in self?.handleBackendError(message) }
        }
#else
        // The dependency-free fast-test runner injects a fake capture above.
        // A missing production backend must never manufacture a grant.
        self.init(prepare: {
            throw NSError(domain: "SystemAudioPermissionProbe", code: 1)
        }, start: { _ in }, stop: {})
#endif
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

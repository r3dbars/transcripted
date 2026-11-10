import Foundation
import Combine

/// The production publisher adapter. Observation authority does not own or
/// stop a native capture, and no host callback runs under its state lock.
final class SystemAudioCaptureObservation: @unchecked Sendable {
    typealias Token = SystemAudioObservationOwnership.Token
    typealias Delivery = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias DelayedDelivery = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    enum ErrorEffect: Sendable {
        case none
        case healAfterDeviceSwitch
    }

    struct Handlers: Sendable {
        let error: @Sendable (Token, String?) -> ErrorEffect
        let recovery: @Sendable (Token, SystemAudioRecoveryEvent) -> Void
        let enqueueGap: @Sendable (Token, TimeInterval) -> Void
        let heal: @Sendable (Token) -> Void
    }

    private let lock = NSLock()
    private let owner = SystemAudioObservationOwnership()
    private let enqueueDelivery: Delivery
    private let enqueueDelayedDelivery: DelayedDelivery
    private var closed = false
    private var binding: Token?
    private var connections: [AnyCancellable] = []

    init(enqueueDelivery: @escaping Delivery, enqueueDelayedDelivery: @escaping DelayedDelivery) {
        self.enqueueDelivery = enqueueDelivery
        self.enqueueDelayedDelivery = enqueueDelayedDelivery
    }

    deinit { cancel() }

    @discardableResult
    func beginSession(generation: UInt64) -> Bool {
        var retired: [AnyCancellable] = []
        let accepted = lock.withLock {
            guard !closed, owner.beginSession(generation: generation) else { return false }
            if let binding, !owner.owns(binding) {
                self.binding = nil
                retired = connections
                connections = []
            }
            return true
        }
        retired.forEach { $0.cancel() }
        return accepted
    }

    func bind(
        generation: UInt64,
        captureID: ObjectIdentifier,
        errors: AnyPublisher<String?, Never>,
        recovery: AnyPublisher<SystemAudioRecoveryEvent, Never>,
        handlers: Handlers
    ) -> Token? {
        var retired: [AnyCancellable] = []
        let token: Token? = lock.withLock {
            guard !closed, let token = owner.bind(generation: generation, captureID: captureID) else { return nil }
            binding = token
            retired = connections
            connections = []
            return token
        }
        retired.forEach { $0.cancel() }
        guard let token else { return nil }

        // Subscribe outside locks: a publisher may emit synchronously or
        // reenter a newer session while constructing these connections.
        let errorConnection = errors.sink { [weak self] message in
            self?.queueError(message, token: token, handlers: handlers)
        }
        let recoveryConnection = recovery.sink { [weak self] event in
            self?.queueRecovery(event, token: token, handlers: handlers)
        }
        let padConnection = recovery.sink { [weak self] event in
            self?.receiveDirectRecovery(event, token: token, handlers: handlers)
        }
        let candidates = [errorConnection, recoveryConnection, padConnection]
        let installed = lock.withLock {
            guard isCurrentLocked(token) else { return false }
            connections = candidates
            return true
        }
        guard installed else {
            candidates.forEach { $0.cancel() }
            return nil
        }
        return token
    }

    func cancel() {
        var retired: [AnyCancellable] = []
        lock.withLock {
            guard !closed else { return }
            closed = true
            binding = nil
            retired = connections
            connections = []
        }
        retired.forEach { $0.cancel() }
    }

    func isCurrent(_ token: Token) -> Bool {
        lock.withLock { isCurrentLocked(token) }
    }

    var isHolding: Bool {
        lock.withLock { !closed && owner.isHolding }
    }

    private func queueError(_ message: String?, token: Token, handlers: Handlers) {
        guard isCurrent(token) else { return }
        enqueueDelivery { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            switch handlers.error(token, message) {
            case .none:
                break
            case .healAfterDeviceSwitch:
                self.enqueueDelayedDelivery(0.5) { [weak self] in
                    guard let self, self.isCurrent(token) else { return }
                    handlers.heal(token)
                }
            }
        }
    }

    private func queueRecovery(_ event: SystemAudioRecoveryEvent, token: Token, handlers: Handlers) {
        guard isCurrent(token) else { return }
        enqueueDelivery { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            handlers.recovery(token, event)
        }
    }

    private func receiveDirectRecovery(_ event: SystemAudioRecoveryEvent, token: Token, handlers: Handlers) {
        switch event {
        case .deviceSwitch, .systemWake, .fellBehind:
            lock.withLock {
                guard isCurrentLocked(token) else { return }
                owner.beginRecovery(token)
            }
        case .recoveryAbandoned:
            endRecoveryIfCurrent(token)
        case .gap(let duration):
            guard isCurrent(token) else { return }
            // The original token travels to the writer. A boundary during
            // this callback may revoke further admission, but must not turn
            // this old end into a release of the successor's hold.
            handlers.enqueueGap(token, duration)
            endRecoveryIfCurrent(token)
        }
    }

    private func endRecoveryIfCurrent(_ token: Token) {
        lock.withLock {
            guard isCurrentLocked(token) else { return }
            owner.endRecovery(token)
        }
    }

    // Adapter lock is held. The sole nested order is adapter -> pure owner;
    // neither owner operations nor these predicates invoke external code.
    private func isCurrentLocked(_ token: Token) -> Bool {
        !closed && binding == token && owner.owns(token)
    }
}

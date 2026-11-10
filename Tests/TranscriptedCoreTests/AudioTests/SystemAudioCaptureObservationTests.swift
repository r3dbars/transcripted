import Combine
import Foundation
import XCTest
@testable import TranscriptedCore

final class SystemAudioCaptureObservationTests: XCTestCase {
    func testQueuedOldEventsAndDirectOldRecoveryCannotAffectTheSuccessor() throws {
        let f = ObservationAdapterFixture()
        defer { f.observation.cancel() }
        let old = ObservationTestSubjects()
        let current = ObservationTestSubjects()
        XCTAssertTrue(f.observation.beginSession(generation: 1))
        let oldToken = try XCTUnwrap(f.bind(old, generation: 1))
        old.errors.send("old synthetic error")
        old.recovery.send(.deviceSwitch)
        XCTAssertTrue(f.observation.isHolding)
        XCTAssertTrue(f.observation.beginSession(generation: 2))
        XCTAssertFalse(f.observation.isHolding)
        let token = try XCTUnwrap(f.bind(current, generation: 2, secondIdentity: true))
        current.recovery.send(.systemWake)
        for event in [SystemAudioRecoveryEvent.deviceSwitch, .systemWake, .fellBehind, .recoveryAbandoned, .gap(duration: 0.25)] {
            old.recovery.send(event)
        }
        XCTAssertFalse(f.observation.isCurrent(oldToken))
        XCTAssertTrue(f.observation.isHolding, "old abandoned/gap events cannot end the successor's hold")
        f.scheduler.deliver()
        XCTAssertTrue(f.record.errors.isEmpty)
        XCTAssertEqual(f.record.recoveries, [.init(token: token, event: .systemWake)])
        XCTAssertTrue(f.record.gaps.isEmpty)
        current.recovery.send(.gap(duration: 1.25))
        XCTAssertEqual(f.record.gaps, [.init(token: token, duration: 1.25, heldAtEnqueue: true)])
        XCTAssertFalse(f.observation.isHolding)
        f.scheduler.deliver()
        XCTAssertEqual(f.record.recoveries.last, .init(token: token, event: .gap(1.25)))
    }

    func testRebindingInOneGenerationRejectsQueuedOldEventsEvenForTheSameIdentity() throws {
        for sameIdentity in [false, true] {
            let f = ObservationAdapterFixture()
            defer { f.observation.cancel() }
            let old = ObservationTestSubjects()
            let current = ObservationTestSubjects()
            XCTAssertTrue(f.observation.beginSession(generation: 10))
            let oldToken = try XCTUnwrap(f.bind(old, generation: 10))
            old.errors.send("old")
            old.recovery.send(.fellBehind)
            let token = try XCTUnwrap(f.bind(current, generation: 10, secondIdentity: !sameIdentity))
            XCTAssertNotEqual(oldToken, token)
            XCTAssertEqual(oldToken.generation, token.generation)
            if sameIdentity { XCTAssertEqual(oldToken.captureID, token.captureID) }
            XCTAssertFalse(f.observation.isHolding)
            current.errors.send("current")
            current.recovery.send(.deviceSwitch)
            old.recovery.send(.recoveryAbandoned)
            XCTAssertTrue(f.observation.isHolding)
            f.scheduler.deliver()
            XCTAssertEqual(f.record.errors, [.init(token: token, message: "current")])
            XCTAssertEqual(f.record.recoveries, [.init(token: token, event: .deviceSwitch)])
            XCTAssertTrue(f.record.gaps.isEmpty)
        }
    }

    func testAdmittedGapEnqueuesBeforeEndAndReentrantBoundaryCannotReleaseANewHold() throws {
        let f = ObservationAdapterFixture()
        defer { f.observation.cancel() }
        let old = ObservationTestSubjects()
        let current = ObservationTestSubjects()
        XCTAssertTrue(f.observation.beginSession(generation: 20))
        let handlers = f.handlers(onGap: { [weak f] _, _ in
            guard let f else { return }
            // This callback is allowed outside ownership locks. It models a
            // new boundary while the old direct gap callback is in flight.
            _ = f.observation.beginSession(generation: 21)
            f.record.successor = f.bind(current, generation: 21, secondIdentity: true)
            current.recovery.send(.systemWake)
        })
        let oldToken = try XCTUnwrap(f.observation.bind(generation: 20, captureID: f.firstID,
                                                       errors: old.errors.eraseToAnyPublisher(),
                                                       recovery: old.recovery.eraseToAnyPublisher(), handlers: handlers))
        old.recovery.send(.deviceSwitch)
        old.recovery.send(.gap(duration: 0.75))
        let token = try XCTUnwrap(f.record.successor)
        XCTAssertFalse(f.observation.isCurrent(oldToken))
        XCTAssertTrue(f.observation.isCurrent(token))
        XCTAssertEqual(f.record.gaps, [.init(token: oldToken, duration: 0.75, heldAtEnqueue: true)])
        XCTAssertTrue(f.observation.isHolding, "the returning old gap must not decrement the new token")
        current.recovery.send(.gap(duration: 0.5))
        XCTAssertEqual(f.record.gaps.last, .init(token: token, duration: 0.5, heldAtEnqueue: true))
        XCTAssertFalse(f.observation.isHolding)
    }

    func testCurrentGapWithoutAnOutstandingRecoveryStillEnqueuesWithoutUnderflow() throws {
        let f = ObservationAdapterFixture()
        defer { f.observation.cancel() }
        let source = ObservationTestSubjects()
        XCTAssertTrue(f.observation.beginSession(generation: 30))
        let token = try XCTUnwrap(f.bind(source, generation: 30))
        source.recovery.send(.gap(duration: 0.25))
        XCTAssertEqual(f.record.gaps, [.init(token: token, duration: 0.25, heldAtEnqueue: false)])
        XCTAssertFalse(f.observation.isHolding)
        source.recovery.send(.systemWake)
        XCTAssertTrue(f.observation.isHolding)
        source.recovery.send(.recoveryAbandoned)
        XCTAssertFalse(f.observation.isHolding)
    }

    func testDelayedHealRunsOnlyWhenDrainedAndAnOldDirectiveCannotHealAfterBoundaryOrRebind() throws {
        for rebindOnly in [false, true] {
            let f = ObservationAdapterFixture()
            defer { f.observation.cancel() }
            let old = ObservationTestSubjects()
            let current = ObservationTestSubjects()
            XCTAssertTrue(f.observation.beginSession(generation: 40))
            _ = try XCTUnwrap(f.bind(old, generation: 40, effect: .healAfterDeviceSwitch))
            old.errors.send("synthetic directive")
            f.scheduler.deliver()
            XCTAssertEqual(f.scheduler.delays, [0.5], "this is the requested delay, not measured elapsed time")
            XCTAssertTrue(f.record.heals.isEmpty)
            let generation: UInt64 = rebindOnly ? 40 : 41
            if !rebindOnly { XCTAssertTrue(f.observation.beginSession(generation: generation)) }
            let token = try XCTUnwrap(f.bind(current, generation: generation, effect: .healAfterDeviceSwitch))
            f.scheduler.deliverDelayed()
            XCTAssertTrue(f.record.heals.isEmpty)
            current.errors.send("current directive")
            f.scheduler.deliver()
            XCTAssertEqual(f.scheduler.delays, [0.5])
            XCTAssertTrue(f.record.heals.isEmpty)
            f.scheduler.deliverDelayed()
            XCTAssertEqual(f.record.heals, [token])
        }
    }

    func testEqualAndStaleBoundariesDoNotDisturbTheCurrentSubscriptionsOrHold() throws {
        let f = ObservationAdapterFixture()
        defer { f.observation.cancel() }
        let current = ObservationTestSubjects()
        let rejected = ObservationTestSubjects()
        XCTAssertTrue(f.observation.beginSession(generation: 50))
        let token = try XCTUnwrap(f.bind(current, generation: 50))
        current.recovery.send(.deviceSwitch)
        XCTAssertTrue(f.observation.beginSession(generation: 50))
        XCTAssertFalse(f.observation.beginSession(generation: 49))
        XCTAssertNil(f.bind(rejected, generation: 49))
        XCTAssertNil(f.bind(rejected, generation: 51))
        XCTAssertTrue(f.observation.isCurrent(token))
        XCTAssertTrue(f.observation.isHolding)
        current.errors.send("still current")
        current.recovery.send(.gap(duration: 0.5))
        rejected.errors.send("rejected")
        f.scheduler.deliver()
        XCTAssertEqual(f.record.errors, [.init(token: token, message: "still current")])
        XCTAssertEqual(f.record.recoveries, [.init(token: token, event: .deviceSwitch), .init(token: token, event: .gap(0.5))])
        XCTAssertEqual(f.record.gaps, [.init(token: token, duration: 0.5, heldAtEnqueue: true)])
        XCTAssertFalse(f.observation.isHolding)
    }

    func testCancelIsTerminalAndMakesQueuedDirectAndDelayedEffectsInert() throws {
        let f = ObservationAdapterFixture()
        defer { f.observation.cancel() }
        let source = ObservationTestSubjects()
        XCTAssertTrue(f.observation.beginSession(generation: 60))
        let token = try XCTUnwrap(f.bind(source, generation: 60, effect: .healAfterDeviceSwitch))
        source.errors.send("schedule heal")
        f.scheduler.deliver()
        let accepted = f.record.errors
        source.errors.send("queued before cancel")
        source.recovery.send(.fellBehind)
        XCTAssertTrue(f.observation.isHolding)
        f.observation.cancel()
        f.observation.cancel()
        XCTAssertFalse(f.observation.isCurrent(token))
        XCTAssertFalse(f.observation.isHolding)
        XCTAssertFalse(f.observation.beginSession(generation: 61))
        XCTAssertNil(f.bind(ObservationTestSubjects(), generation: 61))
        source.recovery.send(.deviceSwitch)
        source.recovery.send(.gap(duration: 0.25))
        f.scheduler.deliver()
        f.scheduler.deliverDelayed()
        XCTAssertEqual(f.record.errors, accepted)
        XCTAssertTrue(f.record.recoveries.isEmpty)
        XCTAssertTrue(f.record.gaps.isEmpty)
        XCTAssertTrue(f.record.heals.isEmpty)
        XCTAssertFalse(f.observation.isHolding)
    }

    func testSynchronousPublisherEventsDuringSubscriptionBelongToTheReservedToken() throws {
        let f = ObservationAdapterFixture()
        defer { f.observation.cancel() }
        XCTAssertTrue(f.observation.beginSession(generation: 70))
        let token = try XCTUnwrap(f.observation.bind(generation: 70, captureID: f.firstID,
            errors: Just<String?>(nil).eraseToAnyPublisher(),
            recovery: Just(SystemAudioRecoveryEvent.deviceSwitch).eraseToAnyPublisher(), handlers: f.handlers()))
        XCTAssertTrue(f.observation.isHolding)
        f.scheduler.deliver()
        XCTAssertEqual(f.record.errors, [.init(token: token, message: nil)])
        XCTAssertTrue(f.scheduler.delays.isEmpty, "a none directive must not schedule a heal")
        XCTAssertEqual(f.record.recoveries, [.init(token: token, event: .deviceSwitch)])
        XCTAssertTrue(f.record.heals.isEmpty)
    }

    func testReentrantSubscriptionCannotInstallItsOldConnectionsOverASuccessor() throws {
        let f = ObservationAdapterFixture()
        defer { f.observation.cancel() }
        let current = ObservationTestSubjects()
        let oldRecovery = PassthroughSubject<SystemAudioRecoveryEvent, Never>()
        let record = f.record
        let trackedRecovery = oldRecovery.handleEvents(
            receiveSubscription: { _ in record.noteSubscription() },
            receiveCancel: { record.noteCancellation() }).eraseToAnyPublisher()
        let errors = Deferred { [weak f] () -> Just<String?> in
            if let f {
                _ = f.observation.beginSession(generation: 81)
                f.record.successor = f.bind(current, generation: 81, secondIdentity: true)
            }
            return Just<String?>("old synchronous event")
        }.eraseToAnyPublisher()
        XCTAssertTrue(f.observation.beginSession(generation: 80))
        let lost = f.observation.bind(generation: 80, captureID: f.firstID, errors: errors,
                                      recovery: trackedRecovery, handlers: f.handlers())
        XCTAssertNil(lost)
        let token = try XCTUnwrap(f.record.successor)
        XCTAssertTrue(f.observation.isCurrent(token))
        XCTAssertEqual(record.cancelledSubscriptions, record.createdSubscriptions,
                       "every old recovery subscription that was built must be cancelled")
        current.errors.send("successor")
        current.recovery.send(.systemWake)
        oldRecovery.send(.recoveryAbandoned)
        f.scheduler.deliver()
        XCTAssertEqual(f.record.errors, [.init(token: token, message: "successor")])
        XCTAssertEqual(f.record.recoveries, [.init(token: token, event: .systemWake)])
        XCTAssertTrue(f.observation.isHolding)
    }
}

private typealias ObservationToken = SystemAudioCaptureObservation.Token

private struct ObservedError: Equatable { let token: ObservationToken; let message: String? }
private struct ObservedRecovery: Equatable { let token: ObservationToken; let event: RecoveryDescriptor }
private struct ObservedGap: Equatable { let token: ObservationToken; let duration: TimeInterval; let heldAtEnqueue: Bool? }
private enum RecoveryDescriptor: Equatable {
    case deviceSwitch, systemWake, fellBehind, abandoned, gap(TimeInterval)
    init(_ event: SystemAudioRecoveryEvent) {
        switch event {
        case .deviceSwitch: self = .deviceSwitch
        case .systemWake: self = .systemWake
        case .fellBehind: self = .fellBehind
        case .gap(let duration): self = .gap(duration)
        case .recoveryAbandoned: self = .abandoned
        }
    }
}

private final class ObservationTestSubjects: @unchecked Sendable {
    let errors = PassthroughSubject<String?, Never>()
    let recovery = PassthroughSubject<SystemAudioRecoveryEvent, Never>()
}

private final class ObservationAdapterMarker {}
private final class ObservationAdapterFixture: @unchecked Sendable {
    let scheduler: ObservationManualDelivery
    let record: ObservationAdapterRecord
    let observation: SystemAudioCaptureObservation
    private let first = ObservationAdapterMarker()
    private let second = ObservationAdapterMarker()
    var firstID: ObjectIdentifier { ObjectIdentifier(first) }

    init() {
        let delivery = ObservationManualDelivery()
        scheduler = delivery
        record = ObservationAdapterRecord()
        observation = SystemAudioCaptureObservation(enqueueDelivery: { delivery.enqueue($0) },
            enqueueDelayedDelivery: { delay, action in delivery.enqueueDelayed(delay, action) })
    }

    func bind(_ source: ObservationTestSubjects, generation: UInt64, secondIdentity: Bool = false,
              effect: SystemAudioCaptureObservation.ErrorEffect = .none) -> ObservationToken? {
        observation.bind(generation: generation, captureID: secondIdentity ? ObjectIdentifier(second) : firstID,
            errors: source.errors.eraseToAnyPublisher(), recovery: source.recovery.eraseToAnyPublisher(),
            handlers: handlers(effect: effect))
    }

    func handlers(effect: SystemAudioCaptureObservation.ErrorEffect = .none,
                  onGap: @escaping @Sendable (ObservationToken, TimeInterval) -> Void = { _, _ in }) -> SystemAudioCaptureObservation.Handlers {
        let record = record
        let observation = observation
        return .init(error: { token, message in
            record.addError(.init(token: token, message: message))
            return effect // Explicit fake directive, not a copy of production string classification.
        }, recovery: { token, event in record.addRecovery(.init(token: token, event: RecoveryDescriptor(event))) },
        enqueueGap: { [weak observation] token, duration in
            record.addGap(.init(token: token, duration: duration, heldAtEnqueue: observation?.isHolding))
            onGap(token, duration)
        }, heal: { token in record.addHeal(token) })
    }
}

private final class ObservationAdapterRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var errorValues: [ObservedError] = []
    private var recoveryValues: [ObservedRecovery] = []
    private var gapValues: [ObservedGap] = []
    private var healValues: [ObservationToken] = []
    private var successorValue: ObservationToken?
    private var subscriptions = 0
    private var cancellations = 0
    var errors: [ObservedError] { lock.withLock { errorValues } }
    var recoveries: [ObservedRecovery] { lock.withLock { recoveryValues } }
    var gaps: [ObservedGap] { lock.withLock { gapValues } }
    var heals: [ObservationToken] { lock.withLock { healValues } }
    var successor: ObservationToken? {
        get { lock.withLock { successorValue } }
        set { lock.withLock { successorValue = newValue } }
    }
    var createdSubscriptions: Int { lock.withLock { subscriptions } }
    var cancelledSubscriptions: Int { lock.withLock { cancellations } }
    func addError(_ value: ObservedError) { lock.withLock { errorValues.append(value) } }
    func addRecovery(_ value: ObservedRecovery) { lock.withLock { recoveryValues.append(value) } }
    func addGap(_ value: ObservedGap) { lock.withLock { gapValues.append(value) } }
    func addHeal(_ value: ObservationToken) { lock.withLock { healValues.append(value) } }
    func noteSubscription() { lock.withLock { subscriptions += 1 } }
    func noteCancellation() { lock.withLock { cancellations += 1 } }
}

private final class ObservationManualDelivery: @unchecked Sendable {
    typealias Action = @Sendable () -> Void
    private let lock = NSLock()
    private var actions: [Action] = []
    private var delayed: [(TimeInterval, Action)] = []
    var delays: [TimeInterval] { lock.withLock { delayed.map(\.0) } }
    func enqueue(_ action: @escaping Action) { lock.withLock { actions.append(action) } }
    func enqueueDelayed(_ delay: TimeInterval, _ action: @escaping Action) {
        lock.withLock { delayed.append((delay, action)) }
    }
    func deliver() {
        let pending = lock.withLock { let value = actions; actions.removeAll(); return value }
        for action in pending { action() }
    }
    func deliverDelayed() {
        let pending = lock.withLock { let value = delayed; delayed.removeAll(); return value }
        for (_, action) in pending { action() }
    }
}

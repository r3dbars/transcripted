import Dispatch
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// Generic lookup only: never construct an installer or use its system steps.
@Suite("Keyboard lookup threading")
@MainActor
struct KeyboardLookupThreadingTests {
    @Test("Unheld preparation leaves main while every native lookup step stays on main")
    func unheldPreparationLeavesMainThreadAndNativeStepsStayOnMain() async throws {
        try requireLookupFixtureEnvironment()
        let preparation = LookupPreparationProbe()
        let native = LookupNativeProbe()
        #expect(native.isMainThread())
        let result = await GhostKeyboardInstallerHost.prepareTrustedSource(
            using: lookupSteps(preparation: preparation, native: native), isCurrent: { true }
        )
        #expect(result == 7)
        #expect(preparation.mainThreadFlags == [false])
        #expect(native.calls == ["identity", "isRegistered", "source"])
        #expect(native.mainThreadFlags == [true, true, true])
    }

    @Test("An unlisted validated source is registered once before lookup")
    func unlistedSourceRegistersOnce() async throws {
        try requireLookupFixtureEnvironment()
        let preparation = LookupPreparationProbe()
        let native = LookupNativeProbe()
        native.registered = false
        let result = await GhostKeyboardInstallerHost.prepareTrustedSource(
            using: lookupSteps(preparation: preparation, native: native), isCurrent: { true }
        )
        #expect(result == 7)
        #expect(native.calls == ["identity", "isRegistered", "register", "source"])
        #expect(native.mainThreadFlags == [true, true, true, true])
        #expect(preparation.mainThreadFlags == [false])
    }

    @Test("Registration failure never reaches source lookup")
    func failedRegistrationDoesNotLookUpSource() async throws {
        try requireLookupFixtureEnvironment()
        let preparation = LookupPreparationProbe()
        let native = LookupNativeProbe()
        native.registered = false
        native.registrationSucceeds = false
        let result = await GhostKeyboardInstallerHost.prepareTrustedSource(
            using: lookupSteps(preparation: preparation, native: native), isCurrent: { true }
        )
        #expect(result == nil)
        #expect(native.calls == ["identity", "isRegistered", "register"])
    }

    @Test("Missing validation never reaches any native step")
    func missingValidationDoesNotReachNativeSteps() async throws {
        try requireLookupFixtureEnvironment()
        let preparation = LookupPreparationProbe()
        let native = LookupNativeProbe()
        let result = await GhostKeyboardInstallerHost.prepareTrustedSource(
            using: lookupSteps(preparation: preparation, native: native, preparedIdentity: nil), isCurrent: { true }
        )
        #expect(result == nil)
        #expect(preparation.mainThreadFlags == [false])
        #expect(native.calls.isEmpty)
    }

    @Test("A current validated registration can still have no source")
    func missingSourceRemainsNil() async throws {
        try requireLookupFixtureEnvironment()
        let preparation = LookupPreparationProbe()
        let native = LookupNativeProbe()
        native.availableSource = nil
        let result = await GhostKeyboardInstallerHost.prepareTrustedSource(
            using: lookupSteps(preparation: preparation, native: native), isCurrent: { true }
        )
        #expect(result == nil)
        #expect(native.calls == ["identity", "isRegistered", "source"])
    }

    @Test("A caller already obsolete before lookup starts performs no validation or native work")
    func obsoleteBeforeLookupDoesNoWork() async throws {
        try requireLookupFixtureEnvironment()
        let preparation = LookupPreparationProbe()
        let native = LookupNativeProbe()
        let result = await GhostKeyboardInstallerHost.prepareTrustedSource(
            using: lookupSteps(preparation: preparation, native: native), isCurrent: { false }
        )
        #expect(result == nil)
        #expect(preparation.mainThreadFlags.isEmpty)
        #expect(native.calls.isEmpty)
    }

    @Test("An already cancelled lookup does not start preparation")
    func cancelledBeforeLookupDoesNoWork() async throws {
        try requireLookupFixtureEnvironment()
        let entry = LookupAsyncSignal()
        let preparation = LookupPreparationProbe()
        let native = LookupNativeProbe()
        let steps = lookupSteps(preparation: preparation, native: native)
        let work = Task { @MainActor in
            await entry.wait()
            return await GhostKeyboardInstallerHost.prepareTrustedSource(using: steps, isCurrent: { true })
        }
        work.cancel()
        entry.signal()
        let result = await work.value
        #expect(result == nil)
        #expect(preparation.mainThreadFlags.isEmpty)
        #expect(native.calls.isEmpty)
    }

    @Test("Held validation cannot authorize a caller that stopped, changed identity or was cancelled",
          arguments: LookupInvalidation.allCases)
    func heldValidationRechecksAuthority(_ invalidation: LookupInvalidation) async throws {
        try requireLookupFixtureEnvironment()
        let preparation = LookupPreparationProbe()
        let native = LookupNativeProbe()
        let currency = LookupCurrency()
        let gate = LookupPreparationGate()
        let steps = lookupSteps(preparation: preparation, native: native, gate: gate)
        let work = Task { @MainActor in
            await GhostKeyboardInstallerHost.prepareTrustedSource(using: steps, isCurrent: { currency.current })
        }
        defer { gate.open() }
        await gate.entered.wait()
        switch invalidation {
        case .callerStopped: currency.current = false
        case .identityChanged: native.currentIdentity = 2
        case .cancelled: work.cancel()
        }
        gate.open()
        let result = await work.value
        #expect(result == nil)
        #expect(preparation.mainThreadFlags == [false])
        #expect(native.calls == (invalidation == .identityChanged ? ["identity"] : []))
        #expect(!native.calls.contains("register"))
        #expect(!native.calls.contains("source"))
    }
}

private func requireLookupFixtureEnvironment() throws {
    try #require(ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1")
}

enum LookupInvalidation: String, CaseIterable, Sendable {
    case callerStopped, identityChanged, cancelled
}

private struct LookupValidation: Sendable { let identity: Int }

@MainActor
private final class LookupCurrency { var current = true }

@MainActor
private final class LookupNativeProbe {
    var currentIdentity = 1
    var registered = true
    var registrationSucceeds = true
    var availableSource: Int? = 7
    var calls: [String] = []
    var mainThreadFlags: [Bool] = []
    func isMainThread() -> Bool { Thread.isMainThread }
    func record(_ call: String) { calls.append(call); mainThreadFlags.append(Thread.isMainThread) }
}

@MainActor
private func lookupSteps(
    preparation: LookupPreparationProbe,
    native: LookupNativeProbe,
    preparedIdentity: Int? = 1,
    gate: LookupPreparationGate? = nil
) -> GhostKeyboardInstallerHost.LookupSteps<LookupValidation, Int> {
    .init(
        prepare: { preparation.prepare(identity: preparedIdentity, gate: gate) },
        identityIsCurrent: { value in
            native.record("identity")
            return value.identity == native.currentIdentity
        },
        isRegistered: { _ in native.record("isRegistered"); return native.registered },
        register: { _ in native.record("register"); return native.registrationSucceeds },
        source: { _ in native.record("source"); return native.availableSource }
    )
}

private final class LookupPreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [Bool] = []
    var mainThreadFlags: [Bool] { lock.lock(); defer { lock.unlock() }; return flags }
    func prepare(identity: Int?, gate: LookupPreparationGate?) -> LookupValidation? {
        lock.lock(); flags.append(Thread.isMainThread); lock.unlock()
        gate?.holdWorker()
        return identity.map { LookupValidation(identity: $0) }
    }
}

/// Only a fake detached preparation may block; the main actor always waits asynchronously.
private final class LookupPreparationGate: @unchecked Sendable {
    let entered = LookupAsyncSignal()
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var opened = false
    func holdWorker() { entered.signal(); semaphore.wait() }
    func open() {
        lock.lock(); let wasOpened = opened; opened = true; lock.unlock()
        if !wasOpened { semaphore.signal() }
    }
}

private final class LookupAsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        lock.lock(); fired = true; let pending = waiters; waiters.removeAll(); lock.unlock()
        for waiter in pending { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { waiter in
            lock.lock()
            if fired { lock.unlock(); waiter.resume() }
            else { waiters.append(waiter); lock.unlock() }
        }
    }
}

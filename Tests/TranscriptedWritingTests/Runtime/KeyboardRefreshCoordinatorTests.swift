import Dispatch
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// Actual coordinator, but every operation, validation and publication is in memory.
@Suite("Keyboard refresh coordinator")
@MainActor
struct KeyboardRefreshCoordinatorTests {
    @Test("Disabled requests do no work and a fresh enabled request publishes its current value")
    func disabledThenCurrentRequest() async throws {
        try requireRefreshFixtureEnvironment()
        let coordinator = WritingKeyboardRefreshCoordinator<Int>()
        let trace = RefreshTrace()
        let disabled = RefreshOperation(1, trace: trace, initiallyReleased: true)
        let current = RefreshOperation(2, trace: trace, initiallyReleased: true)
        let published = RefreshSignal()
        coordinator.request(operation: { await disabled.run($0) }, publish: { trace.published.append($0) })
        coordinator.setEnabled(true)
        coordinator.request(operation: { await current.run($0) }, publish: {
            trace.published.append($0); published.signal()
        })
        await published.wait()
        #expect(trace.started == [2])
        #expect(trace.finished == [2])
        #expect(trace.published == [2])
        #expect(trace.maximumActive == 1)
        #expect(trace.active == 0)
        coordinator.cancel()
    }

    @Test("One active request drains before exactly the latest pending request and rejects its obsolete output")
    func oneActiveAndLatestPending() async throws {
        try requireRefreshFixtureEnvironment()
        let coordinator = WritingKeyboardRefreshCoordinator<Int>()
        coordinator.setEnabled(true)
        let trace = RefreshTrace()
        let first = RefreshOperation(1, trace: trace)
        let replaced = RefreshOperation(2, trace: trace, initiallyReleased: true)
        let latest = RefreshOperation(3, trace: trace, initiallyReleased: true)
        let published = RefreshSignal()
        defer { first.release.signal(); coordinator.cancel() }
        coordinator.request(operation: { await first.run($0) }, publish: { trace.published.append($0) })
        await first.entered.wait()
        #expect(first.isCurrent)
        coordinator.request(operation: { await replaced.run($0) }, publish: { trace.published.append($0) })
        coordinator.request(operation: { await latest.run($0) }, publish: {
            trace.published.append($0); published.signal()
        })
        #expect(!first.isCurrent)
        first.release.signal()
        await published.wait()
        #expect(trace.started == [1, 3])
        #expect(trace.finished == [1, 3])
        #expect(trace.published == [3], "the first operation intentionally returns a value despite obsolete currency")
        #expect(trace.maximumActive == 1)
        #expect(trace.active == 0)
    }

    @Test("Hiding drops pending work and showing with a fresh request waits for the cancelled active return")
    func hideThenResumeLatest() async throws {
        try requireRefreshFixtureEnvironment()
        let coordinator = WritingKeyboardRefreshCoordinator<Int>()
        coordinator.setEnabled(true)
        let trace = RefreshTrace()
        let first = RefreshOperation(1, trace: trace)
        let dropped = RefreshOperation(2, trace: trace, initiallyReleased: true)
        let resumed = RefreshOperation(3, trace: trace, initiallyReleased: true)
        let published = RefreshSignal()
        defer { first.release.signal(); coordinator.cancel() }
        coordinator.request(operation: { await first.run($0) }, publish: { trace.published.append($0) })
        await first.entered.wait()
        coordinator.request(operation: { await dropped.run($0) }, publish: { trace.published.append($0) })
        coordinator.setEnabled(false)
        #expect(!first.isCurrent)
        coordinator.setEnabled(true)
        coordinator.request(operation: { await resumed.run($0) }, publish: {
            trace.published.append($0); published.signal()
        })
        first.release.signal()
        await published.wait()
        #expect(trace.started == [1, 3])
        #expect(trace.finished == [1, 3])
        #expect(trace.published == [3])
        #expect(trace.maximumActive == 1)
        #expect(trace.active == 0)
    }

    @Test("Explicit cancel drops pending work while preserving enablement for a new request")
    func cancelPreservesEnablement() async throws {
        try requireRefreshFixtureEnvironment()
        let coordinator = WritingKeyboardRefreshCoordinator<Int>()
        coordinator.setEnabled(true)
        let trace = RefreshTrace()
        let first = RefreshOperation(1, trace: trace)
        let dropped = RefreshOperation(2, trace: trace, initiallyReleased: true)
        let fresh = RefreshOperation(3, trace: trace, initiallyReleased: true)
        let published = RefreshSignal()
        defer { first.release.signal(); coordinator.cancel() }
        coordinator.request(operation: { await first.run($0) }, publish: { trace.published.append($0) })
        await first.entered.wait()
        coordinator.request(operation: { await dropped.run($0) }, publish: { trace.published.append($0) })
        coordinator.cancel()
        #expect(!first.isCurrent)
        // No setEnabled(true): cancel must preserve the enabled state.
        coordinator.request(operation: { await fresh.run($0) }, publish: {
            trace.published.append($0); published.signal()
        })
        first.release.signal()
        await published.wait()
        #expect(trace.started == [1, 3])
        #expect(trace.finished == [1, 3])
        #expect(trace.published == [3])
        #expect(trace.maximumActive == 1)
        #expect(trace.active == 0)
    }

    @Test("A held generic validation returning after hide cannot register, select or publish")
    func heldLookupAfterHideDoesNotReachNativeSteps() async throws {
        try requireRefreshFixtureEnvironment()
        let coordinator = WritingKeyboardRefreshCoordinator<Int>()
        coordinator.setEnabled(true)
        let trace = RefreshTrace()
        let oldGate = RefreshPreparationGate()
        let oldNative = RefreshNativeProbe()
        let freshNative = RefreshNativeProbe()
        let oldSteps = refreshLookupSteps(native: oldNative, gate: oldGate)
        let freshSteps = refreshLookupSteps(native: freshNative, gate: nil)
        let published = RefreshSignal()
        defer { oldGate.open(); coordinator.cancel() }
        coordinator.request(operation: { current in
            trace.begin(1)
            defer { trace.end(1) }
            guard let source = await GhostKeyboardInstallerHost.prepareTrustedSource(using: oldSteps, isCurrent: current),
                  current(), !Task.isCancelled else { return nil }
            oldNative.selected.append(source)
            return source
        }, publish: { trace.published.append($0) })
        await oldGate.entered.wait()
        coordinator.setEnabled(false)
        coordinator.setEnabled(true)
        // This enabled sentinel proves the obsolete operation has returned
        // before we inspect its publication and native-call trace.
        coordinator.request(operation: { current in
            trace.begin(2)
            defer { trace.end(2) }
            guard let source = await GhostKeyboardInstallerHost.prepareTrustedSource(using: freshSteps, isCurrent: current),
                  current(), !Task.isCancelled else { return nil }
            freshNative.selected.append(source)
            return source
        }, publish: { trace.published.append($0); published.signal() })
        oldGate.open()
        await published.wait()
        #expect(trace.started == [1, 2])
        #expect(trace.finished == [1, 2])
        #expect(trace.maximumActive == 1)
        #expect(oldNative.calls.isEmpty)
        #expect(oldNative.selected.isEmpty)
        #expect(freshNative.calls == ["identity", "isRegistered", "register", "source"])
        #expect(freshNative.mainThreadFlags == [true, true, true, true])
        #expect(freshNative.selected == [7])
        #expect(trace.published == [7])
        #expect(trace.active == 0)
    }
}

private func requireRefreshFixtureEnvironment() throws {
    try #require(ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1")
}

@MainActor
private final class RefreshTrace {
    var started: [Int] = []
    var finished: [Int] = []
    var published: [Int] = []
    var active = 0
    var maximumActive = 0
    func begin(_ id: Int) { started.append(id); active += 1; maximumActive = max(maximumActive, active) }
    func end(_ id: Int) { finished.append(id); active -= 1 }
}

@MainActor
private final class RefreshOperation {
    let entered = RefreshSignal()
    let release = RefreshSignal()
    let id: Int
    let trace: RefreshTrace
    private var currency: (@MainActor () -> Bool)?
    var isCurrent: Bool { currency?() ?? false }
    init(_ id: Int, trace: RefreshTrace, initiallyReleased: Bool = false) {
        self.id = id; self.trace = trace
        if initiallyReleased { release.signal() }
    }
    func run(_ current: @escaping @MainActor () -> Bool) async -> Int? {
        trace.begin(id)
        defer { trace.end(id) }
        currency = current
        entered.signal()
        // Intentionally cancellation-insensitive and returns even when obsolete:
        // rejection must be done by the real coordinator, not by this fake.
        await release.wait()
        return id
    }
}

private struct RefreshValidation: Sendable { let identity: Int }

@MainActor
private final class RefreshNativeProbe {
    var calls: [String] = []
    var mainThreadFlags: [Bool] = []
    var selected: [Int] = []
    func record(_ call: String) { calls.append(call); mainThreadFlags.append(Thread.isMainThread) }
}

@MainActor
private func refreshLookupSteps(
    native: RefreshNativeProbe, gate: RefreshPreparationGate?
) -> GhostKeyboardInstallerHost.LookupSteps<RefreshValidation, Int> {
    .init(
        prepare: { gate?.holdWorker(); return RefreshValidation(identity: 1) },
        identityIsCurrent: { value in native.record("identity"); return value.identity == 1 },
        isRegistered: { _ in native.record("isRegistered"); return false },
        register: { _ in native.record("register"); return true },
        source: { _ in native.record("source"); return 7 }
    )
}

private final class RefreshPreparationGate: @unchecked Sendable {
    let entered = RefreshSignal()
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var opened = false
    func holdWorker() { entered.signal(); semaphore.wait() }
    func open() {
        lock.lock(); let wasOpened = opened; opened = true; lock.unlock()
        if !wasOpened { semaphore.signal() }
    }
}

private final class RefreshSignal: @unchecked Sendable {
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

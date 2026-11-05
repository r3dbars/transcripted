import Foundation
import Testing
@testable import TranscriptedWritingCore
@testable import TranscriptedWritingRuntime

@MainActor
private final class HeldKeyboardStep {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
            let observers = self.observers
            self.observers.removeAll()
            observers.forEach { $0.resume() }
        }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private final class ActivationInputSources: WritingInputSourceProviding {
    var status: GhostKeyboardInstallerHost.TildeInputSourceStatus = .missing
    var selections = 0
    func registeredSourceIsEnabled() -> Bool? { status != .missing }
    func enableRegisteredSource() -> Int32 { 0 }
    func trustedSourceStatus() -> GhostKeyboardInstallerHost.TildeInputSourceStatus { status }
    func selectTrustedSource() -> Bool {
        selections += 1
        status = .selected
        return true
    }
}

@MainActor
private final class KeyboardActionState {
    var stops = 0
    var terminated = false
    var admission: Int? { terminated ? nil : stops }
    var attempts = 0
    var refreshes = 0
    var waits = 0
    var previous: WritingKeyboardSetupState? = .needsUserToAdd
    let sources = ActivationInputSources()

    func refresh() {
        refreshes += 1
        previous = WritingKeyboardInputSource.refresh(
            using: sources, previous: previous,
            firstInstalledThisLoginSession: false, selectedOnce: false
        ).state
    }
}

@Suite("Keyboard actions keep admission through side-effectful refresh")
@MainActor
struct KeyboardActivationFlowTests {
    @Test("Termination without a started runtime invalidates an installing action even when its stop count stays zero")
    func terminatedDuringInitialInstall() async {
        let state = KeyboardActionState()
        let install = HeldKeyboardStep()
        let action = WritingKeyboardActivationFlow.start(
            admission: { state.admission },
            attempt: { state.attempts += 1; await install.wait(); return false },
            refresh: { state.refresh() },
            retryWait: { state.waits += 1 }
        )
        await install.waitForEntry()
        state.terminated = true
        state.sources.status = .available
        install.release()
        await action.value
        #expect(state.stops == 0)
        #expect(state.attempts == 1)
        #expect(state.refreshes == 0)
        #expect(state.waits == 0)
        #expect(state.sources.selections == 0)
    }

    @Test("An already terminated controller cannot start a keyboard action")
    func alreadyTerminated() async {
        let state = KeyboardActionState()
        state.terminated = true
        state.sources.status = .available
        let action = WritingKeyboardActivationFlow.start(
            admission: { state.admission },
            attempt: { state.attempts += 1; return false },
            refresh: { state.refresh() }
        )
        await action.value
        #expect(state.stops == 0)
        #expect(state.attempts == 0)
        #expect(state.refreshes == 0)
        #expect(state.sources.selections == 0)
    }

    @Test("A stop before the scheduled action starts prevents even its first attempt")
    func stoppedBeforeEntry() async {
        let state = KeyboardActionState()
        state.sources.status = .available
        let action = WritingKeyboardActivationFlow.start(
            admission: { state.admission },
            attempt: { state.attempts += 1; return false },
            refresh: { state.refresh() }
        )
        state.stops += 1
        await action.value
        #expect(state.attempts == 0)
        #expect(state.refreshes == 0)
        #expect(state.sources.selections == 0)
    }

    @Test("A stop during installation prevents the refresh that would select a newly available keyboard")
    func stoppedDuringFirstAttempt() async {
        let state = KeyboardActionState()
        let install = HeldKeyboardStep()
        let action = WritingKeyboardActivationFlow.start(
            admission: { state.admission },
            attempt: { state.attempts += 1; await install.wait(); return false },
            refresh: { state.refresh() },
            retryWait: { state.waits += 1 }
        )
        await install.waitForEntry()
        state.stops += 1
        state.sources.status = .available
        install.release()
        await action.value
        #expect(state.attempts == 1)
        #expect(state.refreshes == 0)
        #expect(state.sources.selections == 0)
        #expect(state.waits == 0)
    }

    @Test("The retry wait preserves the original admission instead of starting a new action")
    func stoppedDuringRetryWait() async {
        let state = KeyboardActionState()
        let retry = HeldKeyboardStep()
        let action = WritingKeyboardActivationFlow.start(
            admission: { state.admission },
            attempt: { state.attempts += 1; return false },
            refresh: { state.refresh() },
            retryWait: { state.waits += 1; await retry.wait() }
        )
        await retry.waitForEntry()
        state.stops += 1
        state.sources.status = .available
        retry.release()
        await action.value
        #expect(state.attempts == 1)
        #expect(state.refreshes == 1)
        #expect(state.sources.selections == 0)
    }

    @Test("A stop during the second installation prevents its selecting refresh")
    func stoppedDuringSecondAttempt() async {
        let state = KeyboardActionState()
        let install = HeldKeyboardStep()
        let action = WritingKeyboardActivationFlow.start(
            admission: { state.admission },
            attempt: {
                state.attempts += 1
                if state.attempts == 2 { await install.wait() }
                return false
            },
            refresh: { state.refresh() },
            retryWait: { state.waits += 1 }
        )
        await install.waitForEntry()
        state.stops += 1
        state.sources.status = .available
        install.release()
        await action.value
        #expect(state.attempts == 2)
        #expect(state.refreshes == 1)
        #expect(state.sources.selections == 0)
    }

    @Test("Cancelling an installing action prevents refresh and retry after its work returns")
    func cancelledDuringAttempt() async {
        let state = KeyboardActionState()
        let install = HeldKeyboardStep()
        let action = WritingKeyboardActivationFlow.start(
            admission: { state.admission },
            attempt: { state.attempts += 1; await install.wait(); return false },
            refresh: { state.refresh() },
            retryWait: { state.waits += 1 }
        )
        await install.waitForEntry()
        action.cancel()
        state.sources.status = .available
        install.release()
        await action.value
        #expect(state.refreshes == 0)
        #expect(state.waits == 0)
        #expect(state.sources.selections == 0)
    }

    @Test("An explicit single attempt still refreshes and can select when its admission stays current")
    func admittedSingleAttempt() async {
        let state = KeyboardActionState()
        let action = WritingKeyboardActivationFlow.start(
            admission: { state.admission },
            attempt: { state.attempts += 1; state.sources.status = .available; return false },
            refresh: { state.refresh() }
        )
        await action.value
        #expect(state.attempts == 1)
        #expect(state.refreshes == 1)
        #expect(state.sources.selections == 1)
    }

    @Test("Setup applies intentional reconfiguration before admission and keeps a successful retry")
    func admittedSetupRetryAfterReconfiguration() async {
        let state = KeyboardActionState()
        let action = WritingKeyboardActivationFlow.start(
            prepare: { state.stops += 1 },
            admission: { state.admission },
            attempt: {
                state.attempts += 1
                guard state.attempts == 2 else { return false }
                state.sources.status = .available
                return state.sources.selectTrustedSource()
            },
            refresh: { state.refresh() },
            retryWait: { state.waits += 1 }
        )
        await action.value
        #expect(state.attempts == 2)
        #expect(state.refreshes == 2)
        #expect(state.waits == 1)
        #expect(state.sources.selections == 1)
    }

    @Test("A successful first attempt does not schedule a retry")
    func admittedFirstSuccess() async {
        let state = KeyboardActionState()
        let action = WritingKeyboardActivationFlow.start(
            admission: { state.admission },
            attempt: { state.attempts += 1; return true },
            refresh: { state.refresh() },
            retryWait: { state.waits += 1 }
        )
        await action.value
        #expect(state.attempts == 1)
        #expect(state.refreshes == 1)
        #expect(state.waits == 0)
    }
}

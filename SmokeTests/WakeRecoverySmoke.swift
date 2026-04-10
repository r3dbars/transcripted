import Foundation

@MainActor
private final class HotkeyScript {
    private var scriptedErrors: [String?]
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var currentError: String?

    init(scriptedErrors: [String?]) {
        self.scriptedErrors = scriptedErrors
        self.currentError = scriptedErrors.first ?? nil
    }

    func unregister() {
        unregisterCalls += 1
    }

    func register() {
        registerCalls += 1
        if !scriptedErrors.isEmpty {
            currentError = scriptedErrors.removeFirst()
        }
    }
}

@MainActor
private final class CountBox {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private actor AsyncSignal {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

@main
struct Main {
    static func main() async {
        let exitCode = await runSmoke()
        exit(exitCode)
    }

    @MainActor
    private static func makeCoordinator(
        hotkeys: HotkeyScript,
        readinessCalls: CountBox,
        readinessStarted: AsyncSignal,
        readinessContinue: AsyncSignal,
        sleepCalls: CountBox
    ) -> WakeRecoveryCoordinator {
        WakeRecoveryCoordinator(
            hotkeyRetryAttempts: 3,
            hotkeyRetryDelay: 1,
            unregisterHotkeys: { hotkeys.unregister() },
            registerHotkeys: { hotkeys.register() },
            currentHotkeyError: { hotkeys.currentError },
            waitForRuntimeReadiness: {
                await MainActor.run { readinessCalls.increment() }
                await readinessStarted.open()
                await readinessContinue.wait()
            },
            sleep: { _ in
                await MainActor.run { sleepCalls.increment() }
            }
        )
    }

    private static func runSmoke() async -> Int32 {
        print("[wake-smoke] building scripted wake recovery flow…")

        let hotkeys = await MainActor.run { HotkeyScript(scriptedErrors: ["busy", nil]) }
        let readinessCalls = await MainActor.run { CountBox() }
        let sleepCalls = await MainActor.run { CountBox() }
        let readinessStarted = AsyncSignal()
        let readinessContinue = AsyncSignal()
        let coordinator = await MainActor.run {
            makeCoordinator(
                hotkeys: hotkeys,
                readinessCalls: readinessCalls,
                readinessStarted: readinessStarted,
                readinessContinue: readinessContinue,
                sleepCalls: sleepCalls
            )
        }

        let first = Task { await coordinator.handleSystemWake() }
        await readinessStarted.wait()
        let second = Task { await coordinator.handleSystemWake() }
        await readinessContinue.open()

        let firstResult = await first.value
        let secondResult = await second.value
        let registerCalls = await MainActor.run { hotkeys.registerCalls }
        let readinessCount = await MainActor.run { readinessCalls.count }
        let sleepCount = await MainActor.run { sleepCalls.count }

        guard firstResult.hotkeysRecovered,
              firstResult.performedRecovery,
              secondResult.hotkeysRecovered,
              !secondResult.performedRecovery,
              registerCalls == 2,
              readinessCount == 1,
              sleepCount == 1 else {
            print("[wake-smoke] FAIL")
            print("[wake-smoke]   firstResult: recovered=\(firstResult.hotkeysRecovered) performed=\(firstResult.performedRecovery)")
            print("[wake-smoke]   secondResult: recovered=\(secondResult.hotkeysRecovered) performed=\(secondResult.performedRecovery)")
            print("[wake-smoke]   registerCalls=\(registerCalls) readinessCount=\(readinessCount) sleepCount=\(sleepCount)")
            return 1
        }

        print("[wake-smoke] OK — wake recovery coalesced, retried hotkeys, and waited for readiness")
        return 0
    }
}

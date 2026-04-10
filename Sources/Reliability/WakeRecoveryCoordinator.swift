import Foundation

@MainActor
final class WakeRecoveryCoordinator {
    struct WakeRecoveryResult {
        let hotkeysRecovered: Bool
        let performedRecovery: Bool
        let hotkeyError: String?
    }

    typealias HotkeyUnregister = () -> Void
    typealias HotkeyRegister = () -> Void
    typealias HotkeyErrorProvider = () -> String?
    typealias HotkeyAttemptObserver = (_ attempt: Int, _ error: String?) -> Void
    typealias RuntimeReadinessWaiter = () async -> Void
    typealias Sleep = (_ nanoseconds: UInt64) async -> Void

    private let hotkeyRetryAttempts: Int
    private let hotkeyRetryDelay: UInt64
    private let unregisterHotkeys: HotkeyUnregister
    private let registerHotkeys: HotkeyRegister
    private let currentHotkeyError: HotkeyErrorProvider
    private let onHotkeyAttempt: HotkeyAttemptObserver?
    private let waitForRuntimeReadiness: RuntimeReadinessWaiter
    private let sleep: Sleep

    private var wakeRecoveryTask: Task<(Bool, String?), Never>?

    init(
        hotkeyRetryAttempts: Int,
        hotkeyRetryDelay: UInt64,
        unregisterHotkeys: @escaping HotkeyUnregister,
        registerHotkeys: @escaping HotkeyRegister,
        currentHotkeyError: @escaping HotkeyErrorProvider,
        onHotkeyAttempt: HotkeyAttemptObserver? = nil,
        waitForRuntimeReadiness: @escaping RuntimeReadinessWaiter,
        sleep: @escaping Sleep = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.hotkeyRetryAttempts = max(1, hotkeyRetryAttempts)
        self.hotkeyRetryDelay = hotkeyRetryDelay
        self.unregisterHotkeys = unregisterHotkeys
        self.registerHotkeys = registerHotkeys
        self.currentHotkeyError = currentHotkeyError
        self.onHotkeyAttempt = onHotkeyAttempt
        self.waitForRuntimeReadiness = waitForRuntimeReadiness
        self.sleep = sleep
    }

    func handleSystemWake(onStart: () -> Void = {}) async -> WakeRecoveryResult {
        if let wakeRecoveryTask {
            let (hotkeysRecovered, hotkeyError) = await wakeRecoveryTask.value
            return WakeRecoveryResult(
                hotkeysRecovered: hotkeysRecovered,
                performedRecovery: false,
                hotkeyError: hotkeyError
            )
        }

        onStart()

        let task: Task<(Bool, String?), Never> = Task { @MainActor [weak self] in
            defer { self?.wakeRecoveryTask = nil }

            let hotkeyResult = await self?.recoverHotkeysAfterWake() ?? (false, "Wake recovery coordinator deallocated")
            await self?.waitForRuntimeReadiness()
            return hotkeyResult
        }

        wakeRecoveryTask = task
        let (hotkeysRecovered, hotkeyError) = await task.value
        return WakeRecoveryResult(
            hotkeysRecovered: hotkeysRecovered,
            performedRecovery: true,
            hotkeyError: hotkeyError
        )
    }

    func cancel() {
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
    }

    private func recoverHotkeysAfterWake() async -> (Bool, String?) {
        for attempt in 1...hotkeyRetryAttempts {
            unregisterHotkeys()
            registerHotkeys()

            let hotkeyError = currentHotkeyError()
            onHotkeyAttempt?(attempt, hotkeyError)

            if hotkeyError == nil {
                return (true, nil)
            }

            guard attempt < hotkeyRetryAttempts else { break }
            await sleep(hotkeyRetryDelay)
        }

        return (false, currentHotkeyError())
    }
}

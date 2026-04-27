import Foundation

@MainActor
final class WakeRecoveryCoordinator {
    struct WakeRecoveryResult {
        let hotkeysRecovered: Bool
        let performedRecovery: Bool
        let hotkeyError: String?
    }

    private struct CompletedWakeRecovery {
        let task: Task<(Bool, String?), Never>
        let completedAtUptime: TimeInterval
        let hotkeysRecovered: Bool
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
    private let recentRecoveryReuseWindow: TimeInterval
    private let sleep: Sleep

    private var wakeRecoveryTask: Task<(Bool, String?), Never>?
    private var wakeRecoveryTaskID: UUID?
    private var lastCompletedRecovery: CompletedWakeRecovery?

    init(
        hotkeyRetryAttempts: Int,
        hotkeyRetryDelay: UInt64,
        unregisterHotkeys: @escaping HotkeyUnregister,
        registerHotkeys: @escaping HotkeyRegister,
        currentHotkeyError: @escaping HotkeyErrorProvider,
        onHotkeyAttempt: HotkeyAttemptObserver? = nil,
        waitForRuntimeReadiness: @escaping RuntimeReadinessWaiter,
        recentRecoveryReuseWindow: TimeInterval = 1,
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
        self.recentRecoveryReuseWindow = max(0, recentRecoveryReuseWindow)
        self.sleep = sleep
    }

    func handleSystemWake(onStart: () -> Void = {}) async -> WakeRecoveryResult {
        if let wakeRecoveryTask {
            return await joinedWakeRecoveryResult(for: wakeRecoveryTask)
        }

        if let recentRecoveryTask = recentRecoveryTask() {
            return await joinedWakeRecoveryResult(for: recentRecoveryTask)
        }

        onStart()
        lastCompletedRecovery = nil

        let taskID = UUID()
        let task: Task<(Bool, String?), Never> = Task { @MainActor [weak self] in
            let hotkeyResult = await self?.recoverHotkeysAfterWake() ?? (false, "Wake recovery coordinator deallocated")
            await self?.waitForRuntimeReadiness()
            return hotkeyResult
        }

        wakeRecoveryTask = task
        wakeRecoveryTaskID = taskID
        let (hotkeysRecovered, hotkeyError) = await task.value
        guard wakeRecoveryTaskID == taskID else {
            return WakeRecoveryResult(
                hotkeysRecovered: hotkeysRecovered,
                performedRecovery: true,
                hotkeyError: hotkeyError
            )
        }
        lastCompletedRecovery = hotkeysRecovered
            ? CompletedWakeRecovery(
                task: task,
                completedAtUptime: ProcessInfo.processInfo.systemUptime,
                hotkeysRecovered: hotkeysRecovered
            )
            : nil
        wakeRecoveryTask = nil
        wakeRecoveryTaskID = nil
        return WakeRecoveryResult(
            hotkeysRecovered: hotkeysRecovered,
            performedRecovery: true,
            hotkeyError: hotkeyError
        )
    }

    func cancel() {
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        wakeRecoveryTaskID = nil
        lastCompletedRecovery = nil
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

    private func recentRecoveryTask() -> Task<(Bool, String?), Never>? {
        guard let lastCompletedRecovery, lastCompletedRecovery.hotkeysRecovered else {
            self.lastCompletedRecovery = nil
            return nil
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - lastCompletedRecovery.completedAtUptime
        guard elapsed <= recentRecoveryReuseWindow else {
            self.lastCompletedRecovery = nil
            return nil
        }

        return lastCompletedRecovery.task
    }

    private func joinedWakeRecoveryResult(for task: Task<(Bool, String?), Never>) async -> WakeRecoveryResult {
        let (hotkeysRecovered, hotkeyError) = await task.value
        return WakeRecoveryResult(
            hotkeysRecovered: hotkeysRecovered,
            performedRecovery: false,
            hotkeyError: hotkeyError
        )
    }
}

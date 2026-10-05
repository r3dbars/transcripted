import Foundation

/// Whether the Writing tab's setup finished, and when Writing's runtime
/// should run. Replaces Tilde's setup-window state (`TildeSetupState`): the
/// approved three-step setup in the Writing tab decides everything here
/// (docs/writing-plan.md, "Product design (approved)").
///
/// Foundation only, so the root fast tests compile it.
enum WritingSetupState {
    /// App-suite key (`WritingController.appSuiteName`), set by "Turn on
    /// writing".
    static let completedKey = "WritingSetupCompleted"

    static func isCompleted(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: completedKey)
    }

    static func markCompleted(defaults: UserDefaults) {
        defaults.set(true, forKey: completedKey)
    }
}

/// When `WritingController` runs.
enum WritingActivation {
    /// Runs once setup is done and at least one feature is on. The phase 2
    /// debug default (`WritingDebugEnabled`) still starts it for development.
    static func shouldRun(
        setupCompleted: Bool,
        saveMyWriting: Bool,
        autocomplete: Bool,
        debugEnabled: Bool
    ) -> Bool {
        if debugEnabled { return true }
        return setupCompleted && (saveMyWriting || autocomplete)
    }

    /// A crash leaves the llama helper running, re-parented to launchd,
    /// until something reaps it. Once setup is done, launch reaps it whatever
    /// the feature switches say, so Autocomplete being off can't strand it.
    static func reapsOrphanedHelperAtLaunch(setupCompleted: Bool) -> Bool {
        setupCompleted
    }
}

/// Which frontmost-window watchers run while Writing runs. Save-only users
/// get neither: nothing of theirs uses the frontmost app or window.
enum WritingFrontWindowWatch {
    struct Plan: Equatable {
        /// The `didActivateApplication` observer. It tells the scaffold
        /// prewarmer which app is in front, and Screen Memory when it's on.
        var observesAppActivation: Bool
        /// The 1 Hz `CGWindowListCopyWindowInfo` poll, which only Screen
        /// Memory's same-app window-change trigger needs.
        var pollsFrontWindow: Bool
    }

    static func plan(running: Bool, autocompleteActive: Bool, screenMemoryEnabled: Bool, paused: Bool = false) -> Plan {
        let autocomplete = running && autocompleteActive && !paused
        return Plan(
            observesAppActivation: autocomplete,
            pollsFrontWindow: autocomplete && screenMemoryEnabled
        )
    }
}

/// One expiry wakeup while paused, instead of polling the pause setting.
/// A repeated update keeps the same timer; resume/stop invalidates it.
@MainActor
final class WritingPauseWakeup {
    private(set) var timer: Timer?
    private var deadline: Date?
    private var generation = 0

    func schedule(until: Date?, onExpiry: @escaping @MainActor @Sendable () -> Void) {
        guard until != deadline else { return }
        generation &+= 1
        let expectedGeneration = generation
        timer?.invalidate()
        timer = nil
        deadline = until
        guard let until else { return }
        let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == expectedGeneration else { return }
                self.generation &+= 1
                self.timer = nil
                self.deadline = nil
                onExpiry()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    isolated deinit { timer?.invalidate() }
}

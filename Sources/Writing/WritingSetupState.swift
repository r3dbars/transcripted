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

/// "Turn on writing" tries the keyboard once more a second later, for when
/// Text Input Sources hadn't listed the just-registered keyboard yet. When
/// the enable already reached macOS (it came back still off), macOS is
/// showing its "Allow ... to enable" box over Keyboard settings, and a retry
/// would bring that box straight back after Don't Allow.
enum WritingKeyboardSetupRetry {
    static func retriesAfterTurnOn(keyboardSelected: Bool, enableReachedMacOS: Bool) -> Bool {
        !keyboardSelected && !enableReachedMacOS
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

    static func plan(running: Bool, autocompleteActive: Bool, screenMemoryEnabled: Bool) -> Plan {
        let autocomplete = running && autocompleteActive
        return Plan(
            observesAppActivation: autocomplete,
            pollsFrontWindow: autocomplete && screenMemoryEnabled
        )
    }
}

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
}

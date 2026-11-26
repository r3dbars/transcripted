import Foundation

/// Tracks whether the user has opted into writing capture and when
/// `WritingController` should run. Foundation-only for fast tests.
enum WritingSetupState {
    static let completedKey = "WritingSetupCompleted"

    static func isCompleted(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: completedKey)
    }

    static func markCompleted(defaults: UserDefaults) {
        defaults.set(true, forKey: completedKey)
    }
}

/// When `WritingController` runs: only while opt-in "Save my writing" is
/// enabled (or under the dev-only `WritingDebugEnabled` default).
enum WritingActivation {
    static func shouldRun(
        saveMyWriting: Bool,
        debugEnabled: Bool
    ) -> Bool {
        if debugEnabled { return true }
        return saveMyWriting
    }
}

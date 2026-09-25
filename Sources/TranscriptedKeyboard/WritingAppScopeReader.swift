#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Transcripted: the app scope the Writing tab saves in this keyboard's
/// suite (`WritingAppScope`), read on every key. Only the revision is read
/// each time; the mode and the picked apps are parsed again when it moves.
/// Not part of Tilde.
final class WritingAppScopeReader: @unchecked Sendable {
    static let shared = WritingAppScopeReader(defaults: .standard)

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: (revision: Int, scope: WritingAppScope)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func current() -> WritingAppScope {
        let revision = defaults.integer(forKey: WritingAppScope.revisionKey)
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.revision == revision { return cached.scope }
        let scope = WritingAppScope(
            storedMode: defaults.string(forKey: WritingAppScope.modeKey),
            storedBundleIdentifiers: defaults.stringArray(forKey: WritingAppScope.bundleIdentifiersKey)
        )
        cached = (revision, scope)
        return scope
    }

    /// The Tilde bug fix: the scope and the exclusion list gate suggestions,
    /// not only capture and screen context.
    func allowsSuggestions(in bundleIdentifier: String) -> Bool {
        current().allows(
            bundleIdentifier,
            excludedApps: Set(defaults.stringArray(
                forKey: PersonalHistorySettingsContract.excludedAppsKey
            ) ?? [])
        )
    }
}

#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Reads the opt-in writing app scope (`WritingAppScope`) from the keyboard's
/// shared suite. Only the integer revision is read on every key; the mode and
/// picked apps are re-parsed when the revision changes.
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
}

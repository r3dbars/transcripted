import Foundation

/// Remembers a passed app-seal check for as long as the files that decide
/// it stay put.
///
/// `LlamaServerProcessHost` validates the whole app's code seal before it
/// launches the helper. That check hashes every file in the bundle (models
/// included): ~0.2 s wall and ~0.35 s CPU on a release bundle, and it ran
/// again before every helper start, restart, wake, model switch and
/// port-in-use retry.
///
/// The check itself is unchanged. A pass is remembered per process, keyed by
/// the `lstat` fingerprints (device, inode, size, mtime, ctime, birthtime) of
/// the helper binary and the bundle's `CodeResources`. Swapping, rewriting or
/// re-sealing either one changes its fingerprint and the full check runs
/// again. Both must be regular files, or nothing is remembered. A failure is
/// never remembered, and the lock is never held while validating.
final class BundleSealPassMemo: @unchecked Sendable {
    typealias Fingerprint = [SecureLocalStorage.FileContentFingerprint]

    private let lock = NSLock()
    private var passed: Fingerprint?

    func check(fingerprint: () -> Fingerprint?, validate: () -> Bool) -> Bool {
        let before = fingerprint()
        if let before, lock.withLock({ passed == before }) { return true }
        guard validate() else {
            lock.withLock { passed = nil }
            return false
        }
        // Remember the pass only if nothing moved while it was validating.
        if let before, fingerprint() == before {
            lock.withLock { passed = before }
        }
        return true
    }

    /// The helper binary and the app's `CodeResources`, in that order, or nil
    /// when either is missing or isn't a regular file.
    static func helperSealFingerprint(bundlePath: String) -> Fingerprint? {
        let paths = [
            bundlePath + "/Contents/Helpers/llama-server",
            bundlePath + "/Contents/_CodeSignature/CodeResources",
        ]
        var fingerprints: Fingerprint = []
        for path in paths {
            guard let fingerprint = regularFileFingerprint(atPath: path) else { return nil }
            fingerprints.append(fingerprint)
        }
        return fingerprints
    }

    static func regularFileFingerprint(atPath path: String) -> SecureLocalStorage.FileContentFingerprint? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return SecureLocalStorage.FileContentFingerprint(info)
    }
}

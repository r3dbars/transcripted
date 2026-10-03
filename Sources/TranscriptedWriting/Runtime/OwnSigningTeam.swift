import Foundation
import Security

/// The Team ID this running app is signed with.
///
/// The keyboard installer used to get it from a strict static check of the
/// whole app bundle (nested code, every architecture, every resource). That
/// hashed ~770 MB, models included, on the main thread at launch before the
/// hotkeys registered: about 0.2 s wall and 0.35 s CPU on an M5 Max.
///
/// This asks the running code instead (`SecCodeCopySelf`), the same identity
/// path `GhostBrainServerHost` uses for the socket peers: the kernel already
/// enforces the page signatures of a running process, and reading the
/// signing information does no resource hashing (~2 ms). Ad-hoc and unsigned
/// builds still have no Team ID, so callers fail closed exactly as before.
///
/// Only `[]` or `kSecCSStrictValidate` are valid flags for a running
/// process; the nested-code and all-architecture flags return -67070.
enum OwnSigningTeam {
    private static let memo = NonNilMemo<String>()

    /// Resolved once per process. A nil answer isn't remembered, so a later
    /// call asks again.
    static var current: String? { memo.value(resolve) }

    static func resolve() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
        else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [CFString: Any],
              let team = values[kSecCodeInfoTeamIdentifier] as? String,
              !team.isEmpty else { return nil }
        return team
    }
}

/// Remembers the first non-nil answer for the life of the process. A nil
/// answer is never remembered, so the next call resolves again. The lock is
/// not held while resolving.
final class NonNilMemo<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    func value(_ resolve: () -> Value?) -> Value? {
        if let stored = lock.withLock({ stored }) { return stored }
        guard let resolved = resolve() else { return nil }
        return lock.withLock {
            if let stored { return stored }
            stored = resolved
            return resolved
        }
    }
}

import Foundation

extension FileManager {
    /// Restrict file to owner-only access (chmod 600).
    /// All user data files (transcripts, audio, databases, logs) use this
    /// to prevent world-readable access on multi-user systems.
    func restrictToOwnerOnly(atPath path: String) {
        try? setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

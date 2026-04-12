import Foundation

extension FileManager {
    /// Restrict file to owner-only access (chmod 600).
    /// All user data files (transcripts, audio, databases, logs) use this
    /// to prevent world-readable access on multi-user systems.
    func restrictToOwnerOnly(atPath path: String) {
        try? setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// SQLite writes sensitive state into `-wal` and `-shm` sidecars alongside the
    /// main database file. Harden all three artifacts together so write-ahead data
    /// does not drift to broader default permissions than the primary database.
    func restrictSQLiteArtifactsToOwnerOnly(atPath path: String) {
        let artifacts = [
            path,
            path + "-wal",
            path + "-shm",
        ]

        for artifact in artifacts where fileExists(atPath: artifact) {
            restrictToOwnerOnly(atPath: artifact)
        }
    }
}

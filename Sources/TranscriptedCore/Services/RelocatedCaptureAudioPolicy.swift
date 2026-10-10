import Foundation

/// Decides whether a failed-queue row whose audio sits outside the current
/// capture library should be kept (hidden but durable) instead of rejected.
///
/// The mic path must sit in a `<stem>_audio` directory, and any optional
/// system path must use that same archive layout. Then:
/// - mic file exists: keep.
/// - mic missing, and its old library can't be checked right now — it lives
///   on a `/Volumes/<name>` drive that isn't mounted, or the nearest existing
///   folder above it refuses access — keep until it can be checked.
/// - mic missing and the old library is checkable (its audio folder exists,
///   or the folder was deleted from a mounted, readable disk): the audio is
///   provably gone, so drop the row.
/// A tampered path shaped like an archive on an unmounted volume
/// (`/Volumes/<missing>/x_audio/f.wav`) is kept, not rejected. That is safe:
/// kept rows stay hidden and never retried, and deleting audio still goes
/// through the manager's approved audio roots. Paths without the archive
/// layout (`/tmp`, `..` traversal, arbitrary home files) are rejected.
///
/// One `FileSystem` remembers reachability per library (and per unmounted
/// volume) so N rows on one share don't each pay fileExists / statfs / opendir.
enum RelocatedCaptureAudioPolicy {
    /// The file-system questions the policy asks, injectable so tests never
    /// depend on real mounts or permissions.
    struct FileSystem {
        var fileExists: (String) -> Bool
        var directoryExists: (String) -> Bool
        /// Whether this path is itself the mount point of a mounted volume.
        var isMountPoint: (String) -> Bool
        /// Whether listing this existing directory is refused (permissions, TCC).
        var isAccessDenied: (String) -> Bool
        /// Shared across `shouldKeep` calls that reuse this `FileSystem`.
        var reachability: LibraryReachability = LibraryReachability()

        /// A copy of the probes with an empty cache. Each manager load starts
        /// fresh so a remounted drive is not stuck on the previous answer.
        func withFreshReachability() -> FileSystem {
            FileSystem(
                fileExists: fileExists,
                directoryExists: directoryExists,
                isMountPoint: isMountPoint,
                isAccessDenied: isAccessDenied
            )
        }

        static let live = FileSystem(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            isMountPoint: { path in
                var stats = statfs()
                guard statfs(path, &stats) == 0 else { return false }
                let mountPoint = withUnsafePointer(to: &stats.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                return mountPoint == path
            },
            isAccessDenied: { path in
                if let directory = opendir(path) {
                    closedir(directory)
                    return false
                }
                return errno == EACCES || errno == EPERM
            }
        )
    }

    /// Remembers whether a capture library — or the `/Volumes/<name>` drive
    /// it sits on — can be looked at right now. The manager reuses one
    /// `FileSystem` for the whole load, so the first relocated row pays the
    /// probes and the rest reuse this answer.
    final class LibraryReachability {
        private var uncheckableVolumes: Set<String> = []
        private var uncheckableLibraries: Set<String> = []
        private var checkableLibraries: Set<String> = []

        func isUncheckable(_ audioFolder: URL) -> Bool {
            if let volume = Self.volumeKey(for: audioFolder),
               uncheckableVolumes.contains(volume) {
                return true
            }
            return uncheckableLibraries.contains(Self.libraryKey(for: audioFolder))
        }

        func isCheckable(_ audioFolder: URL) -> Bool {
            checkableLibraries.contains(Self.libraryKey(for: audioFolder))
        }

        func rememberUncheckable(_ audioFolder: URL, volume: String?) {
            uncheckableLibraries.insert(Self.libraryKey(for: audioFolder))
            if let volume {
                uncheckableVolumes.insert(volume)
            }
        }

        func rememberCheckable(_ audioFolder: URL) {
            checkableLibraries.insert(Self.libraryKey(for: audioFolder))
        }

        static func volumeKey(for audioFolder: URL) -> String? {
            let components = audioFolder.pathComponents
            guard components.count >= 3, components[0] == "/", components[1] == "Volumes" else {
                return nil
            }
            return "/Volumes/" + components[2]
        }

        static func libraryKey(for audioFolder: URL) -> String {
            var folder = audioFolder
            if folder.lastPathComponent.hasSuffix("_audio") {
                folder = folder.deletingLastPathComponent()
            }
            return folder.path
        }
    }

    private enum Checkability {
        case checkable
        case uncheckableVolume(String)
        case uncheckableFolder
    }

    /// Both URLs must already be canonical (standardized, symlinks resolved).
    static func shouldKeep(
        micAudioURL micURL: URL,
        systemAudioURL systemURL: URL?,
        fileSystem: FileSystem = .live
    ) -> Bool {
        let archiveDirectory = micURL.deletingLastPathComponent()
        guard archiveDirectory.lastPathComponent.hasSuffix("_audio") else {
            return false
        }
        let systemLooksLikeArchive = systemURL.map {
            $0.deletingLastPathComponent().lastPathComponent.hasSuffix("_audio")
        } ?? true

        // An already-uncheckable library skips fileExists: that call is what
        // hangs on a dead SMB/NFS share, and the first row already paid it.
        if fileSystem.reachability.isUncheckable(archiveDirectory) {
            return systemLooksLikeArchive
        }
        if fileSystem.fileExists(micURL.path) {
            return systemLooksLikeArchive
        }
        if fileSystem.reachability.isCheckable(archiveDirectory) {
            return false
        }
        switch checkability(of: archiveDirectory, fileSystem: fileSystem) {
        case .uncheckableVolume(let volume):
            fileSystem.reachability.rememberUncheckable(archiveDirectory, volume: volume)
            return systemLooksLikeArchive
        case .uncheckableFolder:
            fileSystem.reachability.rememberUncheckable(archiveDirectory, volume: nil)
            return systemLooksLikeArchive
        case .checkable:
            fileSystem.reachability.rememberCheckable(archiveDirectory)
            return false
        }
    }

    /// Whether the old library's archive can't be looked at right now:
    /// its drive isn't mounted, or the nearest existing folder (the audio
    /// archive itself included) refuses access. A readable existing folder, or
    /// a missing one on a mounted readable disk, is checkable.
    static func isUncheckableRightNow(_ audioFolder: URL, fileSystem: FileSystem) -> Bool {
        if case .checkable = checkability(of: audioFolder, fileSystem: fileSystem) {
            return false
        }
        return true
    }

    private static func checkability(of audioFolder: URL, fileSystem: FileSystem) -> Checkability {
        if fileSystem.directoryExists(audioFolder.path) {
            return fileSystem.isAccessDenied(audioFolder.path) ? .uncheckableFolder : .checkable
        }
        if let volume = LibraryReachability.volumeKey(for: audioFolder),
           !fileSystem.directoryExists(volume) || !fileSystem.isMountPoint(volume) {
            return .uncheckableVolume(volume)
        }
        var ancestor = audioFolder.deletingLastPathComponent()
        while ancestor.path != "/", !fileSystem.directoryExists(ancestor.path) {
            ancestor = ancestor.deletingLastPathComponent()
        }
        return fileSystem.isAccessDenied(ancestor.path) ? .uncheckableFolder : .checkable
    }
}

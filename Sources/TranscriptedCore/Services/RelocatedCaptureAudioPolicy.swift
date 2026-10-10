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
/// One `FileSystem` remembers unmounted volumes, denied ancestors, and
/// per-archive checkable answers so N rows on one share don't each pay
/// fileExists / statfs / opendir. Sibling `*_audio` folders keep their own
/// access check.
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

    /// Remembers reachability that applies to a whole share or a denied
    /// ancestor. Per-archive access is not cached at the `meetings/audio`
    /// parent: one missing sibling must not hide another archive that
    /// returns EACCES.
    final class LibraryReachability {
        private var uncheckableVolumes: Set<String> = []
        private var mountedVolumes: Set<String> = []
        private var deniedFolders: Set<String> = []
        private var checkableArchives: Set<String> = []

        func isUncheckable(_ audioFolder: URL) -> Bool {
            if let volume = Self.volumeKey(for: audioFolder),
               uncheckableVolumes.contains(volume) {
                return true
            }
            let path = audioFolder.path
            return deniedFolders.contains { folder in
                path == folder || path.hasPrefix(folder + "/")
            }
        }

        func isCheckableArchive(_ audioFolder: URL) -> Bool {
            checkableArchives.contains(audioFolder.path)
        }

        func isMountedVolume(_ volume: String) -> Bool {
            mountedVolumes.contains(volume)
        }

        func rememberUncheckableVolume(_ volume: String) {
            uncheckableVolumes.insert(volume)
        }

        func rememberDeniedFolder(_ folder: String) {
            deniedFolders.insert(folder)
        }

        func rememberCheckableArchive(_ audioFolder: URL) {
            checkableArchives.insert(audioFolder.path)
        }

        func rememberMountedVolume(_ volume: String) {
            mountedVolumes.insert(volume)
        }

        static func volumeKey(for audioFolder: URL) -> String? {
            let components = audioFolder.pathComponents
            guard components.count >= 3, components[0] == "/", components[1] == "Volumes" else {
                return nil
            }
            return "/Volumes/" + components[2]
        }
    }

    private enum Checkability {
        case checkable
        case uncheckableVolume(String)
        case uncheckableFolder(String)
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
        if fileSystem.reachability.isCheckableArchive(archiveDirectory) {
            return false
        }
        switch checkability(of: archiveDirectory, fileSystem: fileSystem) {
        case .uncheckableVolume(let volume):
            fileSystem.reachability.rememberUncheckableVolume(volume)
            return systemLooksLikeArchive
        case .uncheckableFolder(let folder):
            fileSystem.reachability.rememberDeniedFolder(folder)
            return systemLooksLikeArchive
        case .checkable:
            fileSystem.reachability.rememberCheckableArchive(archiveDirectory)
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
            return fileSystem.isAccessDenied(audioFolder.path)
                ? .uncheckableFolder(audioFolder.path)
                : .checkable
        }
        if let volume = LibraryReachability.volumeKey(for: audioFolder) {
            if !fileSystem.reachability.isMountedVolume(volume) {
                if !fileSystem.directoryExists(volume) || !fileSystem.isMountPoint(volume) {
                    return .uncheckableVolume(volume)
                }
                fileSystem.reachability.rememberMountedVolume(volume)
            }
        }
        var ancestor = audioFolder.deletingLastPathComponent()
        while ancestor.path != "/", !fileSystem.directoryExists(ancestor.path) {
            ancestor = ancestor.deletingLastPathComponent()
        }
        return fileSystem.isAccessDenied(ancestor.path)
            ? .uncheckableFolder(ancestor.path)
            : .checkable
    }
}

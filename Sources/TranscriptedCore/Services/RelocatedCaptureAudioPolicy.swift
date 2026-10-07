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
        if !fileSystem.fileExists(micURL.path),
           !isUncheckableRightNow(archiveDirectory.deletingLastPathComponent(), fileSystem: fileSystem) {
            return false
        }
        guard let systemURL else { return true }
        return systemURL.deletingLastPathComponent().lastPathComponent.hasSuffix("_audio")
    }

    /// Whether the old library's audio folder can't be looked at right now:
    /// its drive isn't mounted, or the nearest existing folder refuses access.
    /// An existing folder, or a missing one on a mounted readable disk, is
    /// checkable.
    static func isUncheckableRightNow(_ audioFolder: URL, fileSystem: FileSystem) -> Bool {
        guard !fileSystem.directoryExists(audioFolder.path) else { return false }
        let components = audioFolder.pathComponents
        if components.count >= 3, components[0] == "/", components[1] == "Volumes" {
            let volume = "/Volumes/" + components[2]
            if !fileSystem.directoryExists(volume) || !fileSystem.isMountPoint(volume) {
                return true
            }
        }
        var ancestor = audioFolder.deletingLastPathComponent()
        while ancestor.path != "/", !fileSystem.directoryExists(ancestor.path) {
            ancestor = ancestor.deletingLastPathComponent()
        }
        return fileSystem.isAccessDenied(ancestor.path)
    }
}

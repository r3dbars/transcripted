import Foundation

/// Creates and tightens Tilde's local on-disk artifacts to owner-only permissions
/// (directories `0700`, files `0600`).
///
/// Tilde writes its privacy-safe diagnostic log under `~/Library`. The file must
/// not depend on a parent directory's mode to stay private, so this helper makes
/// owner-only permissions explicit.
///
/// Opening also tightens existing artifacts, so the first write after upgrading
/// migrates files that were created world-readable by an earlier build.
enum SecureLocalStorage {
    enum ReadOnlyStatusFile {
        case opened(FileHandle)
        case missing
        case rejected
    }

    private enum ExistingStatusDirectory {
        case opened(Int32)
        case missing
        case rejected
    }

    /// Creates and validates the owner-only parent, then opens the exact owner-only regular file.
    /// The parent remains open while `openat` resolves the leaf, so replacing it with a symlink
    /// cannot redirect the write.
    static func openFileForAppending(at file: URL) -> FileHandle? {
        openOwnerOnlyFile(
            at: file,
            flags: O_WRONLY | O_APPEND | O_CREAT
        )
    }

    static func openFileForReadingAndAppending(at file: URL) -> FileHandle? {
        openOwnerOnlyFile(at: file, flags: O_RDWR | O_CREAT, lock: LOCK_EX)
    }

    static func openExistingFileForReading(at file: URL) -> FileHandle? {
        openOwnerOnlyFile(at: file, flags: O_RDONLY, lock: LOCK_SH)
    }

    /// Opens an existing owner-only regular file without following symlinks.
    /// Unlike the append helpers this never creates the leaf.
    static func openExistingFileForReadingAndWriting(at file: URL) -> FileHandle? {
        openOwnerOnlyFile(at: file, flags: O_RDWR, lock: LOCK_EX)
    }

    /// Creates or validates an owner-only directory without following any
    /// symlink in its path.
    static func ensureOwnerOnlyDirectory(at directory: URL) -> Bool {
        guard let descriptor = secureDirectoryDescriptor(at: directory) else { return false }
        close(descriptor)
        return true
    }

    /// Opens an existing private file for status without creating or tightening anything.
    static func openExistingOwnerOnlyFileForReadOnlyStatus(at file: URL) -> ReadOnlyStatusFile {
        let directory = file.deletingLastPathComponent()
        guard !file.lastPathComponent.isEmpty else { return .rejected }
        let directoryDescriptor: Int32
        switch existingOwnerOnlyDirectoryDescriptor(at: directory) {
        case let .opened(opened): directoryDescriptor = opened
        case .missing: return .missing
        case .rejected: return .rejected
        }
        defer { close(directoryDescriptor) }
        var directoryInfo = stat()
        guard flock(directoryDescriptor, LOCK_SH) == 0,
              fstat(directoryDescriptor, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o7777 == 0o700,
              directoryInfo.st_nlink > 0 else { return .rejected }
        let descriptor = openat(
            directoryDescriptor,
            file.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .rejected }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o600 else {
            close(descriptor)
            return .rejected
        }
        guard flock(descriptor, LOCK_SH) == 0,
              fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o600,
              info.st_nlink > 0,
              clearNonblocking(descriptor) else {
            close(descriptor)
            return info.st_nlink == 0 ? .missing : .rejected
        }
        return .opened(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }

    /// Removes only an owner-owned regular file reached through a validated,
    /// non-symlink parent path. Missing files count as already removed.
    static func removeOwnerOnlyFile(at file: URL) -> Bool {
        let directory = file.deletingLastPathComponent()
        guard let directoryDescriptor = secureDirectoryDescriptor(at: directory),
              !file.lastPathComponent.isEmpty else { return false }
        defer { close(directoryDescriptor) }
        var directoryInfo = stat()
        guard flock(directoryDescriptor, LOCK_EX) == 0,
              fstat(directoryDescriptor, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o7777 == 0o700,
              directoryInfo.st_nlink > 0 else { return false }

        let descriptor = openat(
            directoryDescriptor,
            file.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0 { return errno == ENOENT }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              flock(descriptor, LOCK_EX) == 0,
              fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink > 0,
              clearNonblocking(descriptor) else { return false }
        return unlinkat(directoryDescriptor, file.lastPathComponent, 0) == 0
    }

    /// Atomically renames one validated owner-only regular file over another
    /// leaf in the same validated directory. `renameat` replaces a destination
    /// symlink itself rather than following its target.
    static func replaceOwnerOnlyFile(at destination: URL, with source: URL) -> Bool {
        let directory = destination.deletingLastPathComponent()
        guard source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              !source.lastPathComponent.isEmpty,
              !destination.lastPathComponent.isEmpty,
              let directoryDescriptor = secureDirectoryDescriptor(at: directory) else { return false }
        defer { close(directoryDescriptor) }
        guard flock(directoryDescriptor, LOCK_EX) == 0 else { return false }

        let sourceDescriptor = openat(
            directoryDescriptor,
            source.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDescriptor >= 0 else { return false }
        defer { close(sourceDescriptor) }
        var info = stat()
        guard fstat(sourceDescriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o600,
              info.st_nlink > 0 else { return false }
        return renameat(
            directoryDescriptor,
            source.lastPathComponent,
            directoryDescriptor,
            destination.lastPathComponent
        ) == 0
    }

    /// Everything the kernel records about one file's content identity at a
    /// moment: device and inode pin the file, size and modification time
    /// change on any write, and the change time moves on every metadata
    /// write too — including an attempt to set the modification time back.
    /// Two equal fingerprints taken under the same directory lock name the
    /// same bytes.
    struct FileContentFingerprint: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        let createdSeconds: Int
        let createdNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
            createdSeconds = info.st_birthtimespec.tv_sec
            createdNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }

    /// Makes an APFS copy-on-write snapshot of an owner-only regular file,
    /// opens it, and immediately unlinks its name. The returned descriptor is
    /// therefore unaffected by later path replacement or in-place writes to
    /// the installed source inode.
    static func openUnlinkedCloneForReading(at source: URL) -> FileHandle? {
        openUnlinkedCloneForReading(at: source, fingerprint: nil)
    }

    /// `openUnlinkedCloneForReading(at:)` that also reports the source's
    /// content fingerprint, taken on the same descriptor the clone is made
    /// from while the directory lock is held: the clone holds exactly the
    /// bytes that fingerprint describes.
    static func openUnlinkedCloneForReading(
        at source: URL,
        fingerprint: UnsafeMutablePointer<FileContentFingerprint?>?
    ) -> FileHandle? {
        let directory = source.deletingLastPathComponent()
        guard !source.lastPathComponent.isEmpty,
              let directoryDescriptor = secureDirectoryDescriptor(at: directory) else { return nil }
        defer { close(directoryDescriptor) }
        guard flock(directoryDescriptor, LOCK_EX) == 0 else { return nil }

        let sourceDescriptor = openat(
            directoryDescriptor,
            source.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDescriptor >= 0 else { return nil }
        defer { close(sourceDescriptor) }
        var info = stat()
        guard fstat(sourceDescriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o600,
              info.st_nlink > 0 else { return nil }
        fingerprint?.pointee = FileContentFingerprint(info)

        let snapshotName = ".model-runtime-\(UUID().uuidString)"
        guard fclonefileat(sourceDescriptor, directoryDescriptor, snapshotName, 0) == 0 else {
            return nil
        }
        let snapshotDescriptor = openat(
            directoryDescriptor,
            snapshotName,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard snapshotDescriptor >= 0 else {
            _ = unlinkat(directoryDescriptor, snapshotName, 0)
            return nil
        }
        guard fchmod(snapshotDescriptor, 0o400) == 0,
              fstat(snapshotDescriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o400,
              unlinkat(directoryDescriptor, snapshotName, 0) == 0,
              clearNonblocking(snapshotDescriptor) else {
            close(snapshotDescriptor)
            _ = unlinkat(directoryDescriptor, snapshotName, 0)
            return nil
        }
        return FileHandle(fileDescriptor: snapshotDescriptor, closeOnDealloc: true)
    }

    private static func openOwnerOnlyFile(
        at file: URL,
        flags: Int32,
        lock: Int32? = nil
    ) -> FileHandle? {
        let directory = file.deletingLastPathComponent()
        guard let directoryDescriptor = secureDirectoryDescriptor(at: directory),
              !file.lastPathComponent.isEmpty else { return nil }
        defer { close(directoryDescriptor) }
        if let lock {
            var directoryInfo = stat()
            guard flock(directoryDescriptor, lock) == 0,
                  fstat(directoryDescriptor, &directoryInfo) == 0,
                  directoryInfo.st_mode & S_IFMT == S_IFDIR,
                  directoryInfo.st_uid == getuid(),
                  directoryInfo.st_mode & 0o7777 == 0o700,
                  directoryInfo.st_nlink > 0 else { return nil }
        }

        let descriptor = openat(
            directoryDescriptor,
            file.lastPathComponent,
            flags | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { return nil }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              fchmod(descriptor, 0o600) == 0,
              fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o600,
              lock.map({ flock(descriptor, $0) == 0 }) ?? true,
              fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o600,
              info.st_nlink > 0,
              clearNonblocking(descriptor) else {
            close(descriptor)
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func clearNonblocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0
    }

    private static func secureDirectoryDescriptor(at directory: URL) -> Int32? {
        let components = directory.path.split(separator: "/").map(String.init)
        guard directory.isFileURL, !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }

        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return nil }

        for (index, component) in components.enumerated() {
            var child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var wasMissing = false
            if child < 0, errno == ENOENT {
                wasMissing = true
                guard mkdirat(parent, component, 0o700) == 0 || errno == EEXIST else {
                    close(parent)
                    return nil
                }
                child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(parent)
            guard child >= 0 else { return nil }

            let isLeaf = index == components.count - 1
            let mustTighten = wasMissing || isLeaf
            var info = stat()
            guard fstat(child, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR,
                  !mustTighten || tightenDirectory(child, info: &info) else {
                close(child)
                return nil
            }
            parent = child
        }
        return parent
    }

    private static func existingOwnerOnlyDirectoryDescriptor(
        at directory: URL
    ) -> ExistingStatusDirectory {
        let components = directory.path.split(separator: "/").map(String.init)
        guard directory.isFileURL, !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            return .rejected
        }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return .rejected }
        for (index, component) in components.enumerated() {
            let child = openat(
                parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            close(parent)
            guard child >= 0 else { return errno == ENOENT ? .missing : .rejected }
            var info = stat()
            let isLeaf = index == components.count - 1
            guard fstat(child, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR,
                  !isLeaf || (
                    info.st_uid == getuid() && info.st_mode & 0o7777 == 0o700
                  ) else {
                close(child)
                return .rejected
            }
            parent = child
        }
        return .opened(parent)
    }

    private static func tightenDirectory(_ descriptor: Int32, info: inout stat) -> Bool {
        guard info.st_uid == getuid(),
              fchmod(descriptor, 0o700) == 0,
              fstat(descriptor, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR
            && info.st_uid == getuid()
            && info.st_mode & 0o7777 == 0o700
    }
}

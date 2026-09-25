#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import CryptoKit
import Foundation

/// Reuses a model standalone Tilde already downloaded instead of fetching
/// 3.4 to 5.6 GB again (docs/writing-plan.md, "Storage").
///
/// Reads exactly one file in Tilde's folder, `<Tilde models>/<id>/model.gguf`
/// for the chosen descriptor, and nothing else there. The bytes are the trust
/// boundary, same as a download: the file must be a regular file of the
/// pinned size whose SHA-256 matches the pinned descriptor. The clone is taken
/// from the same open descriptor that was hashed, and the source's content
/// fingerprint must be unchanged afterwards, so the adopted bytes are the
/// verified bytes. `ModelManager` still verifies the result on its own before
/// anything runs it.
enum WritingModelAdoption {
    enum Outcome: Equatable, Sendable {
        /// Cloned into Transcripted's model folder.
        case adopted
        /// Transcripted already has a `model.gguf` for this model; nothing read.
        case alreadyInstalled
        /// Tilde has no file for this model.
        case noTildeModel
        /// Tilde's file exists but isn't the pinned model; nothing was copied.
        case rejected(Rejection)
        /// Verified, but the clone or install step failed; nothing was left behind.
        case failed
    }

    enum Rejection: String, Equatable, Sendable {
        case notRegularFile
        case sizeMismatch
        case checksumMismatch
        case unreadable
        case changedWhileVerifying
    }

    static let modelFileName = "model.gguf"
    static let stagingFileName = "model.gguf.adopting"
    static let partialFileName = "model.gguf.partial"

    /// Tilde's production model root at `f36f6562`
    /// (`<Application Support>/Tilde/Models`, from `ModelManager.defaultRootDirectory`
    /// under Tilde's own profile).
    static var defaultTildeModelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tilde", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    static func tildeModelURL(for descriptor: ModelDescriptor, in tildeModelsRoot: URL) -> URL {
        tildeModelsRoot
            .appendingPathComponent(descriptor.identifier, isDirectory: true)
            .appendingPathComponent(modelFileName, isDirectory: false)
    }

    /// Blocking: hashes the whole model. Never call it on the main thread.
    ///
    /// `modelDirectory` is `ModelManager.modelDirectory` for the same
    /// descriptor, which is already symlink-resolved; the owner-only helpers
    /// below refuse any path with a symlink in it.
    static func adoptIfNeeded(
        descriptor: ModelDescriptor,
        modelDirectory: URL,
        tildeModelsRoot: URL
    ) -> Outcome {
        assert(!Thread.isMainThread, "model adoption hashes gigabytes; keep it off the main thread")
        let destination = modelDirectory.appendingPathComponent(modelFileName, isDirectory: false)
        var existing = stat()
        if lstat(destination.path, &existing) == 0 { return .alreadyInstalled }
        guard errno == ENOENT else { return .failed }

        let source = tildeModelURL(for: descriptor, in: tildeModelsRoot)
        // O_NONBLOCK so a FIFO planted at the path can't hang the open; it has
        // no effect on reads from the regular file this goes on to require.
        let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .noTildeModel
            case ELOOP: return .rejected(.notRegularFile)
            default: return .rejected(.unreadable)
            }
        }
        defer { close(sourceDescriptor) }

        var before = stat()
        guard fstat(sourceDescriptor, &before) == 0 else { return .rejected(.unreadable) }
        guard before.st_mode & S_IFMT == S_IFREG else { return .rejected(.notRegularFile) }
        guard before.st_size == descriptor.expectedBytes else { return .rejected(.sizeMismatch) }
        guard let digest = sha256(of: sourceDescriptor) else { return .rejected(.unreadable) }
        guard digest == descriptor.sha256.lowercased() else { return .rejected(.checksumMismatch) }

        guard SecureLocalStorage.ensureOwnerOnlyDirectory(at: modelDirectory) else { return .failed }
        let staging = modelDirectory.appendingPathComponent(stagingFileName, isDirectory: false)
        guard SecureLocalStorage.removeOwnerOnlyFile(at: staging) else { return .failed }
        guard fclonefileat(sourceDescriptor, AT_FDCWD, staging.path, 0) == 0 else { return .failed }

        var after = stat()
        guard fstat(sourceDescriptor, &after) == 0,
              SecureLocalStorage.FileContentFingerprint(after)
                == SecureLocalStorage.FileContentFingerprint(before) else {
            _ = SecureLocalStorage.removeOwnerOnlyFile(at: staging)
            return .rejected(.changedWhileVerifying)
        }

        guard prepareStagedClone(at: staging, expectedBytes: descriptor.expectedBytes) else {
            _ = SecureLocalStorage.removeOwnerOnlyFile(at: staging)
            return .failed
        }
        // RENAME_EXCL: never replace a model.gguf that appeared meanwhile.
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let raced = errno == EEXIST
            _ = SecureLocalStorage.removeOwnerOnlyFile(at: staging)
            return raced ? .alreadyInstalled : .failed
        }
        // A half-finished download of the same model is now dead weight.
        _ = SecureLocalStorage.removeOwnerOnlyFile(
            at: modelDirectory.appendingPathComponent(partialFileName, isDirectory: false)
        )
        return .adopted
    }

    /// The clone keeps Tilde's mode bits; the model store wants an
    /// owner-only, backup-excluded regular file of the pinned size.
    private static func prepareStagedClone(at staging: URL, expectedBytes: Int64) -> Bool {
        let descriptor = open(staging.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_size == expectedBytes,
              fchmod(descriptor, 0o600) == 0 else { return false }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = staging
        return (try? url.setResourceValues(values)) != nil
    }

    private static func sha256(of descriptor: Int32) -> String? {
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var offset: off_t = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                pread(descriptor, bytes.baseAddress, chunkSize, offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { bytes in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes.prefix(count)))
            }
            offset += off_t(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

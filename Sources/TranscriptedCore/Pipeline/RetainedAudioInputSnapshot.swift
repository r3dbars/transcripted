import Darwin
import Foundation

/// Independent inputs for saved-audio reprocessing. Retained WAVs may be
/// recompressed, renamed or deleted while models load or between pipeline reads.
/// Every reader in one job instead uses these same owned bytes.
public final class RetainedAudioInputSnapshot: @unchecked Sendable {
    public let microphoneURL: URL?
    public let systemURL: URL
    public let replacementExpectation: TranscriptReplacementExpectation?
    let directory: URL
    private let root: URL
    private let lock = NSLock()
    private enum Ownership { case preparation, transcription, recovery, discarded }
    private var ownership = Ownership.preparation

    public enum PreparationError: Error {
        case unavailable
        case invalidSource
        case cannotCopy
    }

    private init(microphoneURL: URL?, systemURL: URL, directory: URL, root: URL,
                 replacementExpectation: TranscriptReplacementExpectation?) {
        self.microphoneURL = microphoneURL
        self.systemURL = systemURL
        self.directory = directory
        self.root = root
        self.replacementExpectation = replacementExpectation
    }

    /// `scratchRoot` must be the host's persistent, managed recording scratch:
    /// a deferred speaker-review failure can hand these files to the failed queue.
    public static func prepare(
        microphoneURL: URL?, systemURL: URL, scratchRoot: URL,
        replacementURL: URL? = nil, expectedTranscriptID: UUID? = nil
    ) async throws -> RetainedAudioInputSnapshot {
        try await prepare(microphoneURL: microphoneURL, systemURL: systemURL,
                          scratchRoot: scratchRoot, replacementURL: replacementURL,
                          expectedTranscriptID: expectedTranscriptID, sourceDidOpen: { _ in })
    }

    static func prepare(
        microphoneURL: URL?, systemURL: URL, scratchRoot: URL,
        replacementURL: URL? = nil, expectedTranscriptID: UUID? = nil,
        sourceDidOpen: @escaping @Sendable (URL) -> Void
    ) async throws -> RetainedAudioInputSnapshot {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try prepareSynchronously(microphoneURL: microphoneURL, systemURL: systemURL,
                                     scratchRoot: scratchRoot, replacementURL: replacementURL,
                                     expectedTranscriptID: expectedTranscriptID, sourceDidOpen: sourceDidOpen)
        }
        return try await withTaskCancellationHandler {
            let snapshot = try await worker.value
            try Task.checkCancellation()
            return snapshot
        } onCancel: {
            worker.cancel()
        }
    }

    /// Called before a failed-queue handoff. Files are already durable in the
    /// managed scratch root; a row may keep their URLs without a later copy.
    /// A failed persistence attempt also leaves the bytes available for recovery.
    func preserveForRecovery() {
        lock.lock()
        ownership = .recovery
        lock.unlock()
    }

    /// Only a still-unstarted preparation may be discarded while an outer model
    /// wait retains this object. Once Core claims it, normal reference ownership
    /// keeps the inputs alive until actual work and deferred review have ended.
    @discardableResult public func discardUnstartedPreparation() -> Bool {
        lock.lock()
        guard ownership == .preparation else { lock.unlock(); return false }
        ownership = .discarded
        lock.unlock()
        Self.removeOwnedDirectory(directory, root: root)
        return true
    }

    /// Supersession, cancellation and termination share this same handoff. A
    /// completed copy may still be retained by an older model/migration wait.
    public static func cancelPreparation(_ task: Task<RetainedAudioInputSnapshot, Error>) async {
        task.cancel()
        if let snapshot = try? await task.value { snapshot.discardUnstartedPreparation() }
    }

    func claimForTranscription(microphoneURL: URL?, systemURL: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard ownership == .preparation,
              microphoneURL?.standardizedFileURL.path == self.microphoneURL?.standardizedFileURL.path,
              systemURL.standardizedFileURL.path == self.systemURL.standardizedFileURL.path else { return false }
        ownership = .transcription
        return true
    }

    deinit {
        guard ownership != .recovery else { return }
        Self.removeOwnedDirectory(directory, root: root)
    }

    // The open hook lets owned-file tests arrange unlink/cancellation exactly
    // after admission. Production has no callback or additional filesystem work.
    static func prepareSynchronously(
        microphoneURL: URL?, systemURL: URL, scratchRoot: URL,
        replacementURL: URL? = nil, expectedTranscriptID: UUID? = nil,
        sourceDidOpen: (URL) -> Void = { _ in },
        attemptClone: (Int32, URL) -> Bool = { fclonefileat($0, AT_FDCWD, $1.path, 0) == 0 }
    ) throws -> RetainedAudioInputSnapshot {
        try Task.checkCancellation()
        let expectation = try replacementURL.map {
            try TranscriptReplacementExpectation.capture(
                at: $0, expectedCaptureID: expectedTranscriptID, requiringLegacy: expectedTranscriptID == nil
            )
        }
        let fm = FileManager.default
        if let values = try? scratchRoot.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw PreparationError.cannotCopy
        }
        let root = scratchRoot.standardizedFileURL.resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        guard try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true else {
            throw PreparationError.cannotCopy
        }
        let directory = root.appendingPathComponent("reprocess-\(UUID().uuidString)_audio", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        do {
            let system = try copySource(systemURL, stem: "system_audio", to: directory,
                                        sourceDidOpen: sourceDidOpen, attemptClone: attemptClone)
            let microphone: URL?
            if let microphoneURL {
                microphone = microphoneURL.standardizedFileURL == systemURL.standardizedFileURL
                    ? system
                    : try copySource(microphoneURL, stem: "microphone", to: directory,
                                     sourceDidOpen: sourceDidOpen, attemptClone: attemptClone)
            } else {
                microphone = nil
            }
            try Task.checkCancellation()
            try synchronize(directory)
            return RetainedAudioInputSnapshot(microphoneURL: microphone, systemURL: system,
                                              directory: directory, root: root,
                                              replacementExpectation: expectation)
        } catch {
            removeOwnedDirectory(directory, root: root)
            throw error
        }
    }

    private static func copySource(
        _ source: URL, stem: String, to directory: URL, sourceDidOpen: (URL) -> Void,
        attemptClone: (Int32, URL) -> Bool
    ) throws -> URL {
        try Task.checkCancellation()
        // Opening is the admission point: an open descriptor remains readable
        // after compression or a library operation unlinks the original pathname.
        // Promotion publishes M4A before unlinking WAV, so one bounded fallback
        // handles conversion that already completed before this admission.
        var admitted = source
        var descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT, source.pathExtension.lowercased() == "wav" {
            admitted = source.deletingPathExtension().appendingPathExtension("m4a")
            descriptor = open(admitted.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw PreparationError.unavailable }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else {
            throw PreparationError.invalidSource
        }
        sourceDidOpen(admitted)
        try Task.checkCancellation()
        let destination = directory.appendingPathComponent(stem).appendingPathExtension(admitted.pathExtension)
        // APFS clones avoid copying a long meeting. Unsupported filesystems use
        // a bounded stream from this SAME descriptor, never a second path open.
        if attemptClone(descriptor, destination) {
            guard chmod(destination.path, 0o600) == 0 else { throw PreparationError.cannotCopy }
            try synchronize(destination)
            try Task.checkCancellation()
            return destination
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw PreparationError.cannotCopy
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while try autoreleasepool(invoking: { () throws -> Bool in
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            try output.write(contentsOf: chunk)
            return true
        }) {}
        try output.synchronize()
        return destination
    }

    private static func synchronize(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PreparationError.cannotCopy }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw PreparationError.cannotCopy }
    }

    private static func removeOwnedDirectory(_ directory: URL, root: URL) {
        guard directory.lastPathComponent.hasPrefix("reprocess-"),
              directory.lastPathComponent.hasSuffix("_audio"),
              directory.deletingLastPathComponent().standardizedFileURL.path == root.path,
              root.resolvingSymlinksInPath().path == root.path,
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

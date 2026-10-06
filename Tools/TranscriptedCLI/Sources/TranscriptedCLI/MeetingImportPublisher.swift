import Darwin
import Foundation

struct MeetingImportReceipt: Codable {
    let transcriptPath: String
    let audioPath: String?
    let captureID: String
}

/// Publishes a new meeting without replacing an existing capture. The Markdown
/// is the commit marker: readers cannot see it until retained audio is complete.
enum MeetingImportPublisher {
    private enum PublicationOutcome {
        case preparing, committed, uncertain
    }

    static func publish(
        markdown: String,
        normalizedAudioURL: URL?,
        outputDirectory: URL,
        title: String,
        captureID: UUID,
        date: Date = Date(),
        plainFilename: Bool = false
    ) throws -> MeetingImportReceipt {
        try publish(
            markdown: markdown, normalizedAudioURL: normalizedAudioURL,
            outputDirectory: outputDirectory, title: title, captureID: captureID,
            date: date, plainFilename: plainFilename, beforeCommit: {}
        )
    }

    /// The commit-boundary hook and link operation allow deterministic failure
    /// tests, including a completed remote operation followed by a lost reply.
    /// Production uses the real no-replace link and no additional hook.
    static func publish(
        markdown: String,
        normalizedAudioURL: URL?,
        outputDirectory: URL,
        title: String,
        captureID: UUID,
        date: Date,
        plainFilename: Bool = false,
        beforeCommit: () throws -> Void,
        link: (Int32, String, Int32, String) -> Int32 = { Darwin.linkat($0, $1, $2, $3, 0) }
    ) throws -> MeetingImportReceipt {
        // A plain name (just the title) is tried first when asked for. If that
        // name is already taken, fall back to the unique title + capture ID
        // name instead of failing or replacing anything.
        let stems = fileStems(title: title, captureID: captureID, date: date, plain: plainFilename)
        for (index, stem) in stems.enumerated() {
            do {
                return try publish(
                    markdown: markdown, normalizedAudioURL: normalizedAudioURL,
                    outputDirectory: outputDirectory, stem: stem, captureID: captureID,
                    beforeCommit: beforeCommit, link: link
                )
            } catch let error as NSError
                where index < stems.count - 1 && error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
                continue
            }
        }
        throw failure("Could not choose a meeting file name.", code: EEXIST)
    }

    private static func publish(
        markdown: String,
        normalizedAudioURL: URL?,
        outputDirectory: URL,
        stem: String,
        captureID: UUID,
        beforeCommit: () throws -> Void,
        link: (Int32, String, Int32, String) -> Int32
    ) throws -> MeetingImportReceipt {
        try Task.checkCancellation()
        guard outputDirectory.isFileURL else {
            throw failure("The meeting output directory must be a local file URL.", code: EINVAL)
        }

        // A user-selected library may itself be a symlink. Resolve that root,
        // then anchor every generated child operation to its open descriptor.
        let root = outputDirectory.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let rootFD = try openDirectory(root.path)
        defer { Darwin.close(rootFD) }

        let transcriptName = stem + ".md"
        let archiveName = stem + "_audio"
        let stagingName = ".transcripted-import-\(UUID().uuidString.lowercased()).tmp"
        var stagingOwned = false
        var audioFD: Int32 = -1
        var archiveFD: Int32 = -1
        var archiveOwned = false
        var retainedAudioOwned = false
        var outcome = PublicationOutcome.preparing

        defer {
            if stagingOwned, outcome != .uncertain {
                Darwin.unlinkat(rootFD, stagingName, 0)
            }
            if outcome == .preparing, archiveOwned {
                if archiveFD >= 0 {
                    if retainedAudioOwned {
                        Darwin.unlinkat(archiveFD, "system_audio.wav", 0)
                    }
                    // Never remove a replacement directory installed at this
                    // name after our own directory was created.
                    if directoryMatches(archiveFD, parent: audioFD, name: archiveName) {
                        Darwin.unlinkat(audioFD, archiveName, AT_REMOVEDIR)
                    }
                }
                // If opening our directory failed, do not guess whether the
                // path still belongs to us and recursively delete it.
            }
            if archiveFD >= 0 { Darwin.close(archiveFD) }
            if audioFD >= 0 { Darwin.close(audioFD) }
        }

        var retainedPath: String?
        if let normalizedAudioURL {
            guard normalizedAudioURL.isFileURL else {
                throw failure("Retained audio must be a local file URL.", code: EINVAL)
            }
            if Darwin.mkdirat(rootFD, "audio", 0o700) != 0, errno != EEXIST {
                throw failure("Could not create the meeting audio directory.")
            }
            // The shared audio directory may already exist, but may not be a
            // symlink. Never chmod it: it may belong to the user or another run.
            audioFD = try openDirectory("audio", relativeTo: rootFD)
            guard Darwin.mkdirat(audioFD, archiveName, 0o700) == 0 else {
                throw failure("Could not reserve a new meeting audio archive.")
            }
            archiveOwned = true
            archiveFD = try openDirectory(archiveName, relativeTo: audioFD)
            try copyAudio(from: normalizedAudioURL, into: archiveFD, owned: &retainedAudioOwned)
            guard Darwin.fsync(audioFD) == 0 else {
                throw failure("Could not finish writing the meeting audio directory.")
            }
            try Task.checkCancellation()
            retainedPath = root.appendingPathComponent("audio", isDirectory: true)
                .appendingPathComponent(archiveName, isDirectory: true)
                .appendingPathComponent("system_audio.wav").path
        }

        let stagingFD = Darwin.openat(
            rootFD, stagingName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
        )
        guard stagingFD >= 0 else {
            throw failure("Could not stage the meeting transcript.")
        }
        stagingOwned = true
        do {
            defer { Darwin.close(stagingFD) }
            try Data(markdown.utf8).withUnsafeBytes { bytes in
                try writeAll(bytes, to: stagingFD)
            }
            guard Darwin.fsync(stagingFD) == 0 else {
                throw failure("Could not finish writing the meeting transcript.")
            }
        }

        guard Darwin.fsync(rootFD) == 0 else {
            throw failure("Could not finish preparing the meeting output directory.")
        }
        try beforeCommit()
        try Task.checkCancellation()
        guard directoryMatches(rootFD, path: root.path),
              audioFD < 0 || directoryMatches(audioFD, parent: rootFD, name: "audio"),
              archiveFD < 0 || directoryMatches(archiveFD, parent: audioFD, name: archiveName) else {
            throw failure("The meeting output directory changed during publication.", code: ESTALE)
        }

        // linkat is atomic and refuses ANY existing final entry, including a
        // symlink. Unlike an existence check followed by rename/write, this
        // remains no-clobber when separate CLI processes publish concurrently.
        guard link(rootFD, stagingName, rootFD, transcriptName) == 0 else {
            let code = errno
            if code == ENOTSUP || code == EOPNOTSUPP {
                throw failure(
                    "This filesystem does not support safe transcript publication. "
                        + "Use --output-dir with a local folder and --no-retain-audio, then copy "
                        + "the finished Markdown without replacing an existing file.", code: code
                )
            }
            if code == EEXIST, hasDifferentDestination(rootFD, staged: stagingName, final: transcriptName) {
                throw failure("Could not publish the meeting transcript without replacing an existing file.", code: code)
            }
            // A server can create the link and then lose the acknowledgement.
            // Even EEXIST can be a replay of that successful request: only a
            // different destination proves a collision. Keep recovery files on
            // all other failures; a failed lookup is not proof of nonpublication.
            outcome = .uncertain
            throw NSError(domain: "MeetingImportPublisher.UncertainPublication", code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "Could not confirm transcript publication. Check the output directory "
                    + "before retrying: the transcript may already be saved. The staged Markdown and any retained "
                    + "audio were left in place. \(String(cString: strerror(code)))"
            ])
        }
        outcome = .committed
        // Publication has happened; never turn a late cancellation or a best-
        // effort directory sync failure into deletion of this saved meeting.
        _ = Darwin.fsync(rootFD)
        return MeetingImportReceipt(
            transcriptPath: root.appendingPathComponent(transcriptName).path,
            audioPath: retainedPath,
            captureID: captureID.uuidString
        )
    }

    /// A real collision is a different entry, including a directory or symlink.
    /// An equal identity or an unavailable lookup leaves publication uncertain.
    private static func hasDifferentDestination(_ rootFD: Int32, staged: String, final: String) -> Bool {
        var stagedInfo = stat()
        var finalInfo = stat()
        guard Darwin.fstatat(rootFD, staged, &stagedInfo, AT_SYMLINK_NOFOLLOW) == 0,
              Darwin.fstatat(rootFD, final, &finalInfo, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return stagedInfo.st_dev != finalInfo.st_dev || stagedInfo.st_ino != finalInfo.st_ino
    }

    private static func fileStems(title: String, captureID: UUID, date: Date, plain: Bool) -> [String] {
        let safeTitle = safeFileTitle(title)
        let unique = "\(safeTitle)_\(captureID.uuidString.lowercased())"
        guard plain else { return ["\(dateStamp(date)) \(unique)"] }
        return [safeTitle, unique]
    }

    private static func dateStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    private static func safeFileTitle(_ title: String) -> String {
        var unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        // Foundation includes Unicode format characters in controlCharacters.
        // Keep the joiners required by emoji and scripts such as Persian.
        unsafe.remove(charactersIn: "\u{200C}\u{200D}")
        let cleaned = title.precomposedStringWithCanonicalMapping.unicodeScalars.map { scalar in
            unsafe.contains(scalar) ? " " : String(scalar)
        }.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // Bound the decomposed UTF-8 size too: macOS filesystems may normalize
        // names. Iterate whole characters so Unicode/emoji are never cut apart.
        var bounded = ""
        for character in cleaned {
            let candidate = bounded + String(character)
            guard candidate.decomposedStringWithCanonicalMapping.utf8.count <= 96 else { break }
            bounded = candidate
        }
        // A plain name must never be hidden or be "." / "..".
        let visible = String(bounded.drop(while: { $0 == "." || $0 == " " }))
        return visible.isEmpty ? "Meeting" : visible
    }

    private static func openDirectory(_ path: String, relativeTo parent: Int32? = nil) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let descriptor = parent.map { Darwin.openat($0, path, flags) } ?? Darwin.open(path, flags)
        guard descriptor >= 0 else {
            throw failure("Could not open a real meeting output directory (symlinks below the library root are not allowed).")
        }
        return descriptor
    }

    private static func copyAudio(from source: URL, into archiveFD: Int32, owned: inout Bool) throws {
        // O_NONBLOCK lets the regular-file check reject a FIFO instead of
        // hanging while opening an unexpected non-file source.
        let sourceFD = Darwin.open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw failure("Could not open the normalized audio file.") }
        defer { Darwin.close(sourceFD) }
        var sourceInfo = stat()
        guard Darwin.fstat(sourceFD, &sourceInfo) == 0 else {
            throw failure("Could not inspect the normalized audio file.")
        }
        guard sourceInfo.st_mode & S_IFMT == S_IFREG else {
            throw failure("Normalized audio must be a regular file.", code: EINVAL)
        }
        let targetFD = Darwin.openat(
            archiveFD, "system_audio.wav", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
        )
        guard targetFD >= 0 else { throw failure("Could not create the retained audio file.") }
        owned = true
        defer { Darwin.close(targetFD) }

        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(sourceFD, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw failure("Could not read normalized audio.") }
            if count == 0 { break }
            try buffer.withUnsafeBytes { bytes in
                try writeAll(UnsafeRawBufferPointer(rebasing: bytes[..<count]), to: targetFD)
            }
        }
        guard Darwin.fsync(targetFD) == 0 else { throw failure("Could not finish retaining audio.") }
        guard Darwin.fsync(archiveFD) == 0 else {
            throw failure("Could not finish writing the retained audio directory.")
        }
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw failure("Could not write the meeting artifact.", code: count == 0 ? EIO : errno) }
            offset += count
        }
    }

    private static func directoryMatches(_ descriptor: Int32, parent: Int32, name: String) -> Bool {
        var opened = stat()
        var current = stat()
        return Darwin.fstat(descriptor, &opened) == 0
            && Darwin.fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_mode & S_IFMT == S_IFDIR
            && opened.st_dev == current.st_dev && opened.st_ino == current.st_ino
    }

    private static func directoryMatches(_ descriptor: Int32, path: String) -> Bool {
        var opened = stat()
        var current = stat()
        return Darwin.fstat(descriptor, &opened) == 0
            && Darwin.lstat(path, &current) == 0
            && current.st_mode & S_IFMT == S_IFDIR
            && opened.st_dev == current.st_dev && opened.st_ino == current.st_ino
    }

    private static func failure(_ message: String, code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "\(message) \(String(cString: strerror(code)))"
        ])
    }
}

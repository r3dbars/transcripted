import Foundation

/// The disk side of Save my writing: appends one section to a day file,
/// rewrites a day file when older text is scrubbed, and deletes the day files. The folder comes from the caller (the bridge's
/// injected closure); nothing here decides where the capture library is.
///
/// Every write is atomic: the whole new file goes to an owner-only temporary
/// file in the same folder, which is then renamed over the day file, so a
/// reader never sees half a section. The folder is `0700` and each file
/// `0600` (`SecureLocalStorage`, which also never follows a symlink inside
/// the folder). Not part of Tilde.
enum WritingDayFileStore {
    enum StoreError: Error, Equatable {
        case folderUnavailable
        case unreadableDayFile
        case writeFailed
    }

    /// The folder's own name inside the capture library.
    static let folderName = "writing"
    private static let temporaryPrefix = ".writing-append-"
    private static let temporarySuffix = ".tmp"

    /// Appends `section` to the day file named `fileName`, creating the file
    /// with `header` first when it doesn't exist. Returns the file's URL.
    @discardableResult
    static func append(section: String, header: String, fileName: String, in directory: URL) throws -> URL {
        guard isDayFileName(fileName) else { throw StoreError.writeFailed }
        let folder = resolved(directory)
        guard SecureLocalStorage.ensureOwnerOnlyDirectory(at: folder) else { throw StoreError.folderUnavailable }
        let destination = folder.appendingPathComponent(fileName, isDirectory: false)

        let existing = try existingContents(of: destination)
        let contents = WritingDayFileFormatter.contents(appending: section, to: existing, header: header)
        try writeAtomically(contents, to: destination, in: folder)
        return destination
    }

    /// Reads a day file directly inside `directory`. `nil` when it doesn't
    /// exist; throws when it exists but isn't a readable regular file.
    static func contents(ofDayFile fileName: String, in directory: URL) throws -> Data? {
        guard isDayFileName(fileName) else { throw StoreError.unreadableDayFile }
        return try existingContents(of: resolved(directory).appendingPathComponent(fileName, isDirectory: false))
    }

    /// Whether `fileName` can never be read as a day file however often it's
    /// tried: a bad name, or something other than a regular file this user
    /// owns (a symlink, a folder). A read that failed for any other reason
    /// (open, lock or I/O errors) may work next time.
    static func isNeverReadableDayFile(_ fileName: String, in directory: URL) -> Bool {
        guard isDayFileName(fileName) else { return true }
        var info = stat()
        let path = resolved(directory).appendingPathComponent(fileName, isDirectory: false).path
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT != S_IFREG || info.st_uid != getuid()
    }

    /// Replaces an existing day file's whole contents, atomically, the same
    /// way an append does, but only while it still holds `expected`: a file
    /// that changed or vanished since it was read (an append from another
    /// recorder, delete all) is left alone. Used to scrub files an older
    /// build wrote. Returns the file's URL.
    @discardableResult
    static func replace(dayFile fileName: String, in directory: URL, expected: Data, with contents: Data) throws -> URL {
        guard isDayFileName(fileName) else { throw StoreError.writeFailed }
        let folder = resolved(directory)
        guard SecureLocalStorage.ensureOwnerOnlyDirectory(at: folder) else { throw StoreError.folderUnavailable }
        let destination = folder.appendingPathComponent(fileName, isDirectory: false)
        guard try existingContents(of: destination) == expected else { throw StoreError.writeFailed }
        try writeAtomically(contents, to: destination, in: folder)
        return destination
    }

    /// The names of the `Writing_*.md` files directly inside `directory`.
    /// Refuses a folder not named `writing`, like `deleteAll`.
    static func dayFileNames(in directory: URL) -> [String] {
        guard directory.lastPathComponent == folderName else { return [] }
        let folder = resolved(directory)
        guard folder.lastPathComponent == folderName,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter(isDayFileName).sorted()
    }

    private static func writeAtomically(_ contents: Data, to destination: URL, in folder: URL) throws {
        let temporary = folder.appendingPathComponent(
            temporaryPrefix + UUID().uuidString.lowercased() + temporarySuffix,
            isDirectory: false
        )
        guard let handle = SecureLocalStorage.openFileForAppending(at: temporary) else {
            throw StoreError.writeFailed
        }
        do {
            try handle.write(contentsOf: contents)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            _ = SecureLocalStorage.removeOwnerOnlyFile(at: temporary)
            throw StoreError.writeFailed
        }
        guard SecureLocalStorage.replaceOwnerOnlyFile(at: destination, with: temporary) else {
            _ = SecureLocalStorage.removeOwnerOnlyFile(at: temporary)
            throw StoreError.writeFailed
        }
    }

    /// Deletes every `Writing_*.md` in the writing folder, plus temporary files
    /// an interrupted append left. Refuses a folder not named `writing`, and
    /// removes a file only after checking it sits directly inside the folder.
    /// Never follows a symlink. `true` when nothing deletable is left.
    @discardableResult
    static func deleteAll(in directory: URL) -> Bool {
        guard directory.lastPathComponent == folderName else { return false }
        let folder = resolved(directory)
        guard folder.lastPathComponent == folderName else { return false }
        var info = stat()
        if lstat(folder.path, &info) != 0 { return errno == ENOENT }
        guard info.st_mode & S_IFMT == S_IFDIR,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        var deletedEverything = true
        for name in names {
            let file = folder.appendingPathComponent(name, isDirectory: false)
            guard isDeletable(file, in: folder) else { continue }
            if !SecureLocalStorage.removeOwnerOnlyFile(at: file) { deletedEverything = false }
        }
        return deletedEverything
    }

    /// A `Writing_*.md` file or one of this store's temporary files, directly
    /// inside `folder`. Nothing else in the folder is ever deleted.
    static func isDeletable(_ file: URL, in folder: URL) -> Bool {
        let name = file.lastPathComponent
        let isOurs = isDayFileName(name)
            || (name.hasPrefix(temporaryPrefix) && name.hasSuffix(temporarySuffix))
        guard isOurs, !name.contains("/") else { return false }
        let parent = file.deletingLastPathComponent().standardizedFileURL.path
        return file.isFileURL && folder.isFileURL && parent == folder.standardizedFileURL.path
    }

    static func isDayFileName(_ name: String) -> Bool {
        name.hasPrefix(WritingDayFileFormatter.fileNamePrefix)
            && name.hasSuffix(WritingDayFileFormatter.fileNameExtension)
            && name.count > WritingDayFileFormatter.fileNamePrefix.count
                + WritingDayFileFormatter.fileNameExtension.count
            && !name.contains("/")
    }

    /// The folder with every symlink in its existing part resolved (a capture
    /// library may live under one, and `/var` is one), so the no-follow
    /// checks apply to the real path. `realpath`, not
    /// `resolvingSymlinksInPath()`, which turns `/private/var` back into the
    /// `/var` symlink.
    static func resolved(_ directory: URL) -> URL {
        var existing = directory.standardizedFileURL
        var missing: [String] = []
        while true {
            if let real = realpath(existing.path, nil) {
                defer { free(real) }
                var url = URL(fileURLWithPath: String(cString: real), isDirectory: true)
                for component in missing.reversed() {
                    url.appendPathComponent(component, isDirectory: true)
                }
                return url
            }
            guard existing.pathComponents.count > 1 else { return directory.standardizedFileURL }
            missing.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
    }

    /// `nil` for a day file that doesn't exist yet. A day file that exists
    /// but can't be read is an error, never an empty file to write over.
    private static func existingContents(of file: URL) throws -> Data? {
        var info = stat()
        if lstat(file.path, &info) != 0 {
            guard errno == ENOENT else { throw StoreError.unreadableDayFile }
            return nil
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              let handle = SecureLocalStorage.openExistingFileForReading(at: file) else {
            throw StoreError.unreadableDayFile
        }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd() ?? Data() else { throw StoreError.unreadableDayFile }
        return data
    }
}

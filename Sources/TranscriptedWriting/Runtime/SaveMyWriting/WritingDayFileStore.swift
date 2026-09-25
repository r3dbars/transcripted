import Foundation

/// The disk side of Save my writing: appends one section to a day file and
/// deletes the day files. The folder comes from the caller (the bridge's
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
        return destination
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

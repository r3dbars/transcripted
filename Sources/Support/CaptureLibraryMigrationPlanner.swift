// CaptureLibraryMigrationPlanner.swift
// Migration planning for capture-library relocation: copy, and for Move, a
// separate step that sends the copied originals to the Trash afterwards.

import Foundation

struct CaptureLibraryMigrationItem: Equatable {
    enum Kind: Equatable {
        case meetingTranscript
        case meetingAudioDirectory
        case dictationTranscript
    }

    let kind: Kind
    let sourceURL: URL
    let destinationURL: URL
}

struct CaptureLibraryMigrationPlan: Equatable {
    let itemsToCopy: [CaptureLibraryMigrationItem]
    let skippedExisting: [CaptureLibraryMigrationItem]

    static let empty = CaptureLibraryMigrationPlan(itemsToCopy: [], skippedExisting: [])

    var isEmpty: Bool { itemsToCopy.isEmpty && skippedExisting.isEmpty }
}

struct CaptureLibraryMigrationResult: Equatable {
    let copiedCount: Int
    let skippedExistingCount: Int
    /// What was copied, with each source's state from just before its copy.
    /// Move uses this to remove only originals that are still exactly what
    /// got copied.
    var copiedItems: [CaptureLibraryCopiedItem] = []
}

struct CaptureLibraryCopiedItem: Equatable {
    let item: CaptureLibraryMigrationItem
    let sourceFingerprint: CaptureLibrarySourceFingerprint?
}

/// Size, file count, and newest modification date of a file or of every file
/// under a directory. Cheap enough to take per item, and any append (a new
/// dictation on today's day file) or added file changes it.
struct CaptureLibrarySourceFingerprint: Equatable {
    let totalBytes: Int64
    let fileCount: Int
    let newestModificationDate: Date?
}

struct CaptureLibraryOriginalsRemovalResult: Equatable {
    /// Originals sent to the Trash (or already gone).
    let removedCount: Int
    /// Originals that changed after they were copied, left in place so
    /// nothing written in the meantime is lost.
    let keptChangedCount: Int
    /// Originals that could not be moved to the Trash.
    let failedCount: Int
}

enum CaptureLibraryMigrationError: Error, LocalizedError {
    case copyFailed(sourcePath: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .copyFailed(sourcePath, underlying):
            return "Could not copy \(sourcePath): \(underlying.localizedDescription)"
        }
    }
}

struct CaptureLibraryMigrationPlanner {
    private let fileManager: FileManager
    private let removeOriginal: (URL) throws -> Void

    /// `removeOriginal` defaults to moving the item to the Trash, so a Move
    /// can always be undone from Finder. Tests inject a plain delete.
    init(
        fileManager: FileManager = .default,
        removeOriginal: ((URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.removeOriginal = removeOriginal ?? { url in
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
    }

    func libraryHasCaptures(at library: URL) -> Bool {
        let meetings = meetingsDirectory(in: library)
        let dictations = dictationsDirectory(in: library)

        if !markdownFiles(in: meetings).isEmpty { return true }
        if !directoryContents(of: audioDirectory(in: meetings)).isEmpty { return true }
        if !markdownFiles(in: dictations).isEmpty { return true }
        return false
    }

    func makePlan(from oldLibrary: URL, to newLibrary: URL) -> CaptureLibraryMigrationPlan {
        let source = oldLibrary.standardizedFileURL
        let destination = newLibrary.standardizedFileURL
        guard source.path != destination.path else { return .empty }

        var itemsToCopy: [CaptureLibraryMigrationItem] = []
        var skippedExisting: [CaptureLibraryMigrationItem] = []

        func plan(_ kind: CaptureLibraryMigrationItem.Kind, from sourceURL: URL, into destinationDirectory: URL) {
            let item = CaptureLibraryMigrationItem(
                kind: kind,
                sourceURL: sourceURL,
                destinationURL: destinationDirectory.appendingPathComponent(
                    sourceURL.lastPathComponent,
                    isDirectory: kind == .meetingAudioDirectory
                )
            )
            if fileManager.fileExists(atPath: item.destinationURL.path) {
                skippedExisting.append(item)
            } else {
                itemsToCopy.append(item)
            }
        }

        let sourceMeetings = meetingsDirectory(in: source)
        let destinationMeetings = meetingsDirectory(in: destination)
        for transcript in markdownFiles(in: sourceMeetings) {
            plan(.meetingTranscript, from: transcript, into: destinationMeetings)
        }

        let destinationAudio = audioDirectory(in: destinationMeetings)
        for retainedAudio in retainedAudioDirectories(in: audioDirectory(in: sourceMeetings)) {
            plan(.meetingAudioDirectory, from: retainedAudio, into: destinationAudio)
        }

        let destinationDictations = dictationsDirectory(in: destination)
        for dayFile in markdownFiles(in: dictationsDirectory(in: source)) {
            plan(.dictationTranscript, from: dayFile, into: destinationDictations)
        }

        return CaptureLibraryMigrationPlan(itemsToCopy: itemsToCopy, skippedExisting: skippedExisting)
    }

    func copy(
        _ plan: CaptureLibraryMigrationPlan,
        onProgress: ((_ copied: Int, _ total: Int) -> Void)? = nil
    ) throws -> CaptureLibraryMigrationResult {
        var copied = 0
        var skipped = plan.skippedExisting.count
        let total = plan.itemsToCopy.count
        var copiedItems: [CaptureLibraryCopiedItem] = []

        for item in plan.itemsToCopy {
            if fileManager.fileExists(atPath: item.destinationURL.path) {
                skipped += 1
                continue
            }

            // Stage into a hidden sibling, then move into place. Copying straight
            // to the destination leaves a half-populated <stem>_audio/ directory
            // when it throws mid-tree, and both the planner's collision check and
            // the pre-copy recheck above are bare existence checks — so a retry
            // classifies that residue as skippedExisting, reports success, and
            // applyCaptureLibraryChoice switches the library to a truncated copy.
            // moveItem within one directory is atomic, so the destination only
            // ever appears complete. Same shape as convertWAVToM4AAtomically.
            // Fingerprint before copying, so a write that lands during or
            // after the copy shows up as a change and Move keeps the original.
            let sourceFingerprint = fingerprint(of: item.sourceURL)
            let staging = item.destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(".\(item.destinationURL.lastPathComponent).partial-\(UUID().uuidString)")

            do {
                try fileManager.createPrivateDirectory(at: item.destinationURL.deletingLastPathComponent())
                try fileManager.copyItem(at: item.sourceURL, to: staging)
                try fileManager.moveItem(at: staging, to: item.destinationURL)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw CaptureLibraryMigrationError.copyFailed(
                    sourcePath: item.sourceURL.path,
                    underlying: error
                )
            }

            copied += 1
            copiedItems.append(CaptureLibraryCopiedItem(item: item, sourceFingerprint: sourceFingerprint))
            onProgress?(copied, total)
        }

        return CaptureLibraryMigrationResult(
            copiedCount: copied,
            skippedExistingCount: skipped,
            copiedItems: copiedItems
        )
    }

    /// The second half of a Move: after the copy finished and the library
    /// switched, remove each original that is still exactly what was copied.
    /// An original is kept when its copy is missing at the destination or
    /// when it changed after it was copied (for example, a dictation appended
    /// to today's file before the switch). Items the plan skipped because the
    /// destination already had that name are never passed here, so they stay.
    func removeOriginals(of copiedItems: [CaptureLibraryCopiedItem]) -> CaptureLibraryOriginalsRemovalResult {
        var removed = 0
        var keptChanged = 0
        var failed = 0

        for copiedItem in copiedItems {
            let source = copiedItem.item.sourceURL
            guard fileManager.fileExists(atPath: source.path) else {
                removed += 1
                continue
            }
            guard fileManager.fileExists(atPath: copiedItem.item.destinationURL.path),
                  let expected = copiedItem.sourceFingerprint,
                  fingerprint(of: source) == expected else {
                keptChanged += 1
                continue
            }
            do {
                try removeOriginal(source)
                removed += 1
            } catch {
                failed += 1
            }
        }

        return CaptureLibraryOriginalsRemovalResult(
            removedCount: removed,
            keptChangedCount: keptChanged,
            failedCount: failed
        )
    }

    func fingerprint(of url: URL) -> CaptureLibrarySourceFingerprint? {
        // attributesOfItem(atPath:) always reads the file system. URL
        // resourceValues can hand back values cached on the URL from the
        // pre-copy read, which would make a mid-move append look unchanged.
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        var totalBytes: Int64 = 0
        var fileCount = 0
        var newest: Date?

        func include(path: String) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return }
            totalBytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            fileCount += 1
            if let date = attributes[.modificationDate] as? Date, newest.map({ date > $0 }) ?? true {
                newest = date
            }
        }

        if isDirectory(url) {
            guard let enumerator = fileManager.enumerator(atPath: url.path) else { return nil }
            for case let relativePath as String in enumerator {
                include(path: (url.path as NSString).appendingPathComponent(relativePath))
            }
        } else {
            include(path: url.path)
        }

        return CaptureLibrarySourceFingerprint(
            totalBytes: totalBytes,
            fileCount: fileCount,
            newestModificationDate: newest
        )
    }

    private func meetingsDirectory(in library: URL) -> URL {
        library.appendingPathComponent("meetings", isDirectory: true)
    }

    private func dictationsDirectory(in library: URL) -> URL {
        library.appendingPathComponent("dictations", isDirectory: true)
    }

    private func audioDirectory(in meetings: URL) -> URL {
        meetings.appendingPathComponent("audio", isDirectory: true)
    }

    private func directoryContents(of directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private func markdownFiles(in directory: URL) -> [URL] {
        directoryContents(of: directory)
            .filter { $0.pathExtension.lowercased() == "md" && !isDirectory($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func retainedAudioDirectories(in audioDirectory: URL) -> [URL] {
        directoryContents(of: audioDirectory)
            .filter { isDirectory($0) && $0.lastPathComponent.hasSuffix("_audio") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// The status line Settings shows after a Move finishes.
enum CaptureLibraryMoveSummary {
    static func text(
        copy: CaptureLibraryMigrationResult,
        removal: CaptureLibraryOriginalsRemovalResult,
        oldLibraryPath: String
    ) -> String {
        var sentences: [String] = []
        if removal.removedCount > 0 {
            sentences.append("Moved \(items(removal.removedCount)) to the new folder. The old copies are in the Trash.")
        } else if copy.copiedCount == 0 && copy.skippedExistingCount == 0 {
            sentences.append("Switched to the new folder. There was nothing to move.")
        } else {
            sentences.append("Switched to the new folder.")
        }
        if removal.keptChangedCount > 0 {
            sentences.append("\(items(removal.keptChangedCount)) changed during the move, so the newest \(removal.keptChangedCount == 1 ? "version is" : "versions are") still in \(oldLibraryPath).")
        }
        if removal.failedCount > 0 {
            sentences.append("\(items(removal.failedCount)) couldn't go to the Trash and \(removal.failedCount == 1 ? "is" : "are") still in \(oldLibraryPath).")
        }
        if copy.skippedExistingCount > 0 {
            sentences.append("\(items(copy.skippedExistingCount)) stayed in \(oldLibraryPath) because the new folder already had \(copy.skippedExistingCount == 1 ? "a file" : "files") with the same name.")
        }
        return sentences.joined(separator: " ")
    }

    private static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}

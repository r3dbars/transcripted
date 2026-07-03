// CaptureLibraryMigrationPlanner.swift
// Copy-only migration planning for capture-library relocation.

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

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
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

        for item in plan.itemsToCopy {
            if fileManager.fileExists(atPath: item.destinationURL.path) {
                skipped += 1
                continue
            }

            do {
                try fileManager.createPrivateDirectory(at: item.destinationURL.deletingLastPathComponent())
                try fileManager.copyItem(at: item.sourceURL, to: item.destinationURL)
            } catch {
                throw CaptureLibraryMigrationError.copyFailed(
                    sourcePath: item.sourceURL.path,
                    underlying: error
                )
            }

            copied += 1
            onProgress?(copied, total)
        }

        return CaptureLibraryMigrationResult(copiedCount: copied, skippedExistingCount: skipped)
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

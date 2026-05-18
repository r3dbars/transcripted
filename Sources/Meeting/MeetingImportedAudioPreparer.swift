import Foundation
import UniformTypeIdentifiers

struct PreparedImportedMeetingAudio: Sendable {
    let copiedAudioURL: URL
    let suggestedTitle: String
}

enum MeetingImportedAudioPreparationError: LocalizedError, Equatable {
    case fileMissing
    case cannotInspect
    case notRegularFile
    case unsupportedAudioType
    case unreadable
    case copyFailed

    var diagnosticKind: String {
        switch self {
        case .fileMissing:
            return MeetingFailureKind.importFileMissing.rawValue
        case .cannotInspect,
             .unreadable:
            return MeetingFailureKind.importFileUnreadable.rawValue
        case .notRegularFile,
             .unsupportedAudioType:
            return MeetingFailureKind.importUnsupportedFile.rawValue
        case .copyFailed:
            return MeetingFailureKind.importCopyFailed.rawValue
        }
    }

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            return "The selected audio file could not be found. It may have been moved or deleted."
        case .cannotInspect:
            return "Transcripted couldn't inspect that audio file. Check Finder permissions and try again."
        case .notRegularFile:
            return "Choose an audio file, not a folder or app package."
        case .unsupportedAudioType:
            return "That file does not look like audio. Choose a WAV, MP3, M4A, AAC, or AIFF file."
        case .unreadable:
            return "Transcripted couldn't read that audio file. Try moving it to a folder you can access."
        case .copyFailed:
            return "Transcripted couldn't copy that audio file into its working area. Check disk space and try again."
        }
    }
}

enum MeetingImportedAudioPreparer {
    static func prepareImportedAudio(
        from sourceURL: URL,
        scratchDirectory: URL = MeetingStoragePaths.recordingsScratch
    ) throws -> PreparedImportedMeetingAudio {
        let fileManager = FileManager.default
        fileManager.ensurePrivateDirectory(
            at: scratchDirectory,
            context: "meeting imported audio scratch"
        )

        let resolvedSourceURL = sourceURL.standardizedFileURL
        guard fileManager.fileExists(atPath: resolvedSourceURL.path) else {
            throw MeetingImportedAudioPreparationError.fileMissing
        }

        let didStartSecurityScope = resolvedSourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                resolvedSourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceAttributes: [FileAttributeKey: Any]
        do {
            sourceAttributes = try fileManager.attributesOfItem(atPath: resolvedSourceURL.path)
        } catch {
            throw MeetingImportedAudioPreparationError.cannotInspect
        }

        guard sourceAttributes[.type] as? FileAttributeType == .typeRegular else {
            throw MeetingImportedAudioPreparationError.notRegularFile
        }

        let resourceValues: URLResourceValues
        do {
            resourceValues = try resolvedSourceURL.resourceValues(forKeys: [
                .contentTypeKey,
                .isReadableKey
            ])
        } catch {
            throw MeetingImportedAudioPreparationError.cannotInspect
        }

        if resourceValues.isReadable == false {
            throw MeetingImportedAudioPreparationError.unreadable
        }

        if let contentType = resourceValues.contentType,
           !contentType.conforms(to: .audio) {
            throw MeetingImportedAudioPreparationError.unsupportedAudioType
        }

        let destinationURL = uniqueScratchURL(
            for: resolvedSourceURL,
            in: scratchDirectory,
            fileManager: fileManager
        )

        do {
            try fileManager.copyItem(at: resolvedSourceURL, to: destinationURL)
            fileManager.restrictFileToOwnerOnly(at: destinationURL)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw MeetingImportedAudioPreparationError.copyFailed
        }

        return PreparedImportedMeetingAudio(
            copiedAudioURL: destinationURL,
            suggestedTitle: suggestedTitle(from: resolvedSourceURL)
        )
    }

    private static func uniqueScratchURL(
        for sourceURL: URL,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        let originalExtension = sourceURL.pathExtension
        let safeExtension = originalExtension.isEmpty ? "m4a" : originalExtension
        let stem = "imported-\(UUID().uuidString)"
        var candidate = directory
            .appendingPathComponent(stem, isDirectory: false)
            .appendingPathExtension(safeExtension)
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(stem)-\(suffix)", isDirectory: false)
                .appendingPathExtension(safeExtension)
            suffix += 1
        }

        return candidate
    }

    private static func suggestedTitle(from sourceURL: URL) -> String {
        let raw = sourceURL
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return raw.isEmpty ? "Imported audio" : raw
    }
}

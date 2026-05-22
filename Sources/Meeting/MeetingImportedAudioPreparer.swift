import Foundation
import AVFoundation
import UniformTypeIdentifiers

struct PreparedImportedMeetingAudio: Sendable {
    let copiedAudioURL: URL
    let suggestedTitle: String
    let recordingDate: Date
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
    ) async throws -> PreparedImportedMeetingAudio {
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
            suggestedTitle: suggestedTitle(from: resolvedSourceURL),
            recordingDate: await recordingDate(
                from: resolvedSourceURL,
                sourceAttributes: sourceAttributes
            )
        )
    }

    private static func recordingDate(
        from sourceURL: URL,
        sourceAttributes: [FileAttributeKey: Any]
    ) async -> Date {
        if let embeddedDate = await embeddedRecordingDate(from: sourceURL) {
            return embeddedDate
        }

        if let creationDate = sourceAttributes[.creationDate] as? Date {
            return creationDate
        }

        if let resourceDate = try? sourceURL.resourceValues(forKeys: [.creationDateKey]).creationDate {
            return resourceDate
        }

        if let modificationDate = sourceAttributes[.modificationDate] as? Date {
            return modificationDate
        }

        return Date()
    }

    private static func embeddedRecordingDate(from sourceURL: URL) async -> Date? {
        let asset = AVURLAsset(url: sourceURL)
        return await embeddedRecordingDate(from: asset)
    }

    static func embeddedRecordingDate(from asset: AVURLAsset) async -> Date? {
        if let creationDate = try? await asset.load(.creationDate),
           let date = await metadataDate(creationDate) {
            return date
        }

        let metadata = (try? await asset.load(.metadata)) ?? []
        var dates: [Date] = []
        for item in metadata where isRecordingDateMetadata(item) {
            if let date = await metadataDate(item) {
                dates.append(date)
            }
        }
        return dates.sorted().first
    }

    private static func isRecordingDateMetadata(_ item: AVMetadataItem) -> Bool {
        let fields = [
            item.identifier?.rawValue,
            item.commonKey?.rawValue,
            item.keySpace?.rawValue,
            item.key.map { String(describing: $0) }
        ]
        let joined = fields
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        return joined.contains("creation")
            || joined.contains("created")
            || joined.contains("recorded")
            || joined.contains("recordingdate")
            || joined.contains("date")
    }

    static func metadataDate(
        _ item: AVMetadataItem,
        defaultTimeZone: TimeZone = .current
    ) async -> Date? {
        if let string = try? await item.load(.stringValue),
           let date = parseMetadataDate(string, defaultTimeZone: defaultTimeZone) {
            return date
        }

        if let value = try? await item.load(.value) {
            if let date = value as? Date {
                return date
            }
            if let string = value as? String,
               let date = parseMetadataDate(string, defaultTimeZone: defaultTimeZone) {
                return date
            }
            if let string = value as? NSString,
               let date = parseMetadataDate(String(string), defaultTimeZone: defaultTimeZone) {
                return date
            }
        }

        if let date = try? await item.load(.dateValue) {
            return date
        }

        return nil
    }

    static func parseMetadataDate(
        _ value: String,
        defaultTimeZone: TimeZone = .current
    ) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ssZ",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        formatter.timeZone = defaultTimeZone
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
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

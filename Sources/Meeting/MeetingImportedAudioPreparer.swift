import Foundation
import AVFoundation
import Darwin
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif
import UniformTypeIdentifiers

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
            return "Choose an audio or video recording file, not a folder or app package."
        case .unsupportedAudioType:
            return "That file does not include a readable audio track. Choose a WAV, MP3, M4A, AAC, AIFF, MP4, or MOV file."
        case .unreadable:
            return "Transcripted couldn't read that audio file. Try moving it to a folder you can access."
        case .copyFailed:
            return "Transcripted couldn't copy or extract that recording into its working area. Check disk space and try again."
        }
    }
}

enum MeetingImportedAudioPreparer {
    static func prepareImportedAudio(
        from sourceURL: URL,
        scratchDirectory: URL = MeetingStoragePaths.recordingsScratch
    ) async throws -> PreparedImportedMeetingAudio {
        // Bail before doing any work if the import was already cancelled, so an
        // explicit cancel never even starts copying.
        try Task.checkCancellation()

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

        let mediaKind = try importMediaKind(for: resourceValues.contentType)

        let destinationURL = uniqueScratchURL(
            for: resolvedSourceURL,
            in: scratchDirectory,
            fileManager: fileManager,
            preferredExtension: mediaKind == .audiovisual ? "m4a" : nil
        )

        var sourceContentKey: String?
        do {
            switch mediaKind {
            case .audio:
                sourceContentKey = try copyInterruptibly(
                    from: resolvedSourceURL,
                    to: destinationURL,
                    fileManager: fileManager
                )
            case .audiovisual:
                sourceContentKey = try ImportedAudioContentKey.ofFile(at: resolvedSourceURL)
                try await extractAudioTrack(
                    from: resolvedSourceURL,
                    to: destinationURL
                )
            }
            fileManager.restrictFileToOwnerOnly(at: destinationURL)
        } catch is CancellationError {
            try? fileManager.removeItem(at: destinationURL)
            throw CancellationError()
        } catch let error as MeetingImportedAudioPreparationError {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw MeetingImportedAudioPreparationError.copyFailed
        }

        return PreparedImportedMeetingAudio(
            copiedAudioURL: destinationURL,
            sourceContentKey: sourceContentKey,
            suggestedTitle: suggestedTitle(from: resolvedSourceURL),
            recordingDate: await recordingDate(
                from: resolvedSourceURL,
                sourceAttributes: sourceAttributes
            )
        )
    }

    static func importMediaKind(for contentType: UTType?) throws -> ImportedMeetingMediaKind {
        guard let contentType else { return .audio }
        if contentType.conforms(to: .audio) {
            return .audio
        }
        if contentType.conforms(to: .audiovisualContent) || contentType.conforms(to: .movie) {
            return .audiovisual
        }
        throw MeetingImportedAudioPreparationError.unsupportedAudioType
    }

    static func extractAudioTrack(
        from sourceURL: URL,
        to destinationURL: URL
    ) async throws {
        try Task.checkCancellation()

        let asset = AVURLAsset(url: sourceURL)
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw MeetingImportedAudioPreparationError.unsupportedAudioType
        }

        guard !audioTracks.isEmpty else {
            throw MeetingImportedAudioPreparationError.unsupportedAudioType
        }
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw MeetingImportedAudioPreparationError.unsupportedAudioType
        }

        exportSession.shouldOptimizeForNetworkUse = false

        try await exportSession.export(to: destinationURL, as: .m4a)
        try Task.checkCancellation()
    }

    /// Recording-date resolution lives in Core (`ImportedRecordingDate`) so the CLI
    /// dates imports the same way.
    private static func recordingDate(
        from sourceURL: URL,
        sourceAttributes: [FileAttributeKey: Any]
    ) async -> Date {
        await ImportedRecordingDate.resolve(from: sourceURL, sourceAttributes: sourceAttributes)
    }

    /// Streams the source file into scratch in chunks so an explicit cancel can
    /// interrupt a large import between chunks instead of blocking inside one
    /// atomic `copyItem` call. Any partial destination is removed before this
    /// throws — on cancellation or on a copy error — so a cancelled or failed
    /// import never leaves an ambiguous half-written file behind. Returns the
    /// source's content key (`ImportedAudioContentKey`), hashed from the same chunks.
    @discardableResult static func copyInterruptibly(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager,
        chunkSize: Int = 1 << 20
    ) throws -> String {
        let readHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? readHandle.close() }

        guard fileManager.createFile(
            atPath: destinationURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw MeetingImportedAudioPreparationError.copyFailed
        }

        let writeHandle: FileHandle
        do {
            writeHandle = try FileHandle(forWritingTo: destinationURL)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }

        var contentHasher = ImportedAudioContentKey.Hasher()
        do {
            // One pool per chunk: without it every chunk's Data stays alive until the
            // loop ends, so the copy would hold (and leave dirty) the whole file.
            while try autoreleasepool(invoking: { () throws -> Bool in
                try Task.checkCancellation()
                guard let chunk = try readHandle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
                contentHasher.update(chunk); try writeHandle.write(contentsOf: chunk); return true }) {}
            try writeHandle.close()
            return contentHasher.finalize()
        } catch {
            try? writeHandle.close()
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private static func uniqueScratchURL(
        for sourceURL: URL,
        in directory: URL,
        fileManager: FileManager,
        preferredExtension: String? = nil
    ) -> URL {
        let originalExtension = sourceURL.pathExtension
        let safeExtension = preferredExtension ?? (originalExtension.isEmpty ? "m4a" : originalExtension)
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
        // A saved dictation recording sent here by the dictation pill's
        // Transcribe It button. Its file is named for the session id, which
        // would otherwise become a title like "dictation 1a2b…".
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        if stem.hasPrefix("dictation_"),
           UUID(uuidString: String(stem.dropFirst("dictation_".count))) != nil {
            return "Saved dictation"
        }
        let raw = sourceURL
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return raw.isEmpty ? "Imported audio" : raw
    }
}

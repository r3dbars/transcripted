import Foundation

struct PreparedImportedMeetingAudio {
    let copiedAudioURL: URL
    let suggestedTitle: String
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
            throw NSError(
                domain: "MeetingImportedAudioPreparer",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "The selected audio file could not be found."
                ]
            )
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
            throw NSError(
                domain: "MeetingImportedAudioPreparer",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Transcripted couldn't copy that audio file into its working area."
                ]
            )
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

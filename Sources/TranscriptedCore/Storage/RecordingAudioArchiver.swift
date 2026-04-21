import Foundation

struct RetainedRecordingAudio: Equatable {
    let directory: URL
    let micURL: URL?
    let systemURL: URL?
}

enum RecordingAudioArchiver {
    static func archive(
        micURL: URL?,
        systemURL: URL?,
        transcriptURL: URL,
        archiveRoot: URL,
        fileManager: FileManager = .default
    ) throws -> RetainedRecordingAudio {
        guard micURL != nil || systemURL != nil else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = archiveRoot.appendingPathComponent(
            "\(transcriptURL.deletingPathExtension().lastPathComponent)_audio",
            isDirectory: true
        )
        try createPrivateDirectory(at: directory, fileManager: fileManager)

        let archivedMicURL = try micURL.map {
            try copyAudioFile(
                from: $0,
                to: directory.appendingPathComponent("microphone").appendingPathExtension(fileExtension(for: $0)),
                fileManager: fileManager
            )
        }

        let systemStem = micURL == nil ? "recording" : "system_audio"
        let archivedSystemURL = try systemURL.map {
            try copyAudioFile(
                from: $0,
                to: directory.appendingPathComponent(systemStem).appendingPathExtension(fileExtension(for: $0)),
                fileManager: fileManager
            )
        }

        return RetainedRecordingAudio(
            directory: directory,
            micURL: archivedMicURL,
            systemURL: archivedSystemURL
        )
    }

    private static func copyAudioFile(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let finalURL = uniqueURL(for: destinationURL, fileManager: fileManager)
        try fileManager.copyItem(at: sourceURL, to: finalURL)
        fileManager.restrictToOwnerOnly(atPath: finalURL.path)
        return finalURL
    }

    private static func createPrivateDirectory(at url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func fileExtension(for url: URL) -> String {
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return ext.isEmpty ? "wav" : ext
    }

    private static func uniqueURL(for url: URL, fileManager: FileManager) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var suffix = 2

        while true {
            let candidate = directory
                .appendingPathComponent("\(stem)-\(suffix)")
                .appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}

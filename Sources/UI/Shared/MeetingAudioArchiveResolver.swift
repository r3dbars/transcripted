import Foundation

struct MeetingAudioAttachment: Equatable, Sendable {
    let directoryURL: URL
    let urls: [URL]

    var id: String {
        urls.map { $0.standardizedFileURL.path }.joined(separator: "|")
    }

    var isCompositePlayback: Bool {
        urls.count > 1
    }
}

enum MeetingAudioArchiveResolver {
    private static let playbackStem = "playback"
    private static let importedStem = "recording"
    private static let systemStem = "system_audio"
    private static let microphoneStem = "microphone"

    static func attachment(
        forTranscript transcriptURL: URL,
        fileManager: FileManager = .default
    ) -> MeetingAudioAttachment? {
        let directoryURL = archiveDirectory(forTranscript: transcriptURL)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let regularFiles = files.filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }

        if let playbackURL = firstAudioFile(named: playbackStem, in: regularFiles) {
            return MeetingAudioAttachment(directoryURL: directoryURL, urls: [playbackURL])
        }

        if let importedURL = firstAudioFile(named: importedStem, in: regularFiles) {
            return MeetingAudioAttachment(directoryURL: directoryURL, urls: [importedURL])
        }

        let liveURLs = [
            firstAudioFile(named: systemStem, in: regularFiles),
            firstAudioFile(named: microphoneStem, in: regularFiles)
        ].compactMap { $0 }

        guard !liveURLs.isEmpty else { return nil }
        return MeetingAudioAttachment(directoryURL: directoryURL, urls: liveURLs)
    }

    static func archiveDirectory(forTranscript transcriptURL: URL) -> URL {
        transcriptURL
            .deletingLastPathComponent()
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("\(transcriptURL.deletingPathExtension().lastPathComponent)_audio", isDirectory: true)
    }

    private static func firstAudioFile(named stem: String, in urls: [URL]) -> URL? {
        urls
            .filter { $0.deletingPathExtension().lastPathComponent == stem }
            .sorted { lhs, rhs in
                lhs.pathExtension.localizedCaseInsensitiveCompare(rhs.pathExtension) == .orderedAscending
            }
            .first
    }
}

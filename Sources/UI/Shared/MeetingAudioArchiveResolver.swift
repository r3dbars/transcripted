import Foundation

struct MeetingAudioAttachment: Equatable, Sendable {
    let directoryURL: URL
    let urls: [URL]
    let retranscriptionURLs: [URL]

    init(directoryURL: URL, urls: [URL], retranscriptionURLs: [URL]? = nil) {
        self.directoryURL = directoryURL
        self.urls = urls
        self.retranscriptionURLs = retranscriptionURLs ?? urls
    }

    var id: String {
        urls.map { $0.standardizedFileURL.path }.joined(separator: "|")
    }

    var isCompositePlayback: Bool {
        urls.count > 1
    }

    var retranscriptionInput: MeetingRetranscriptionInput? {
        MeetingRetranscriptionInput.make(from: retranscriptionURLs)
    }
}

struct MeetingRetranscriptionInput: Equatable, Sendable {
    let micURL: URL?
    let systemURL: URL

    static func make(from urls: [URL]) -> MeetingRetranscriptionInput? {
        let filesByStem = urls.reduce(into: [String: URL]()) { result, url in
            let stem = url.deletingPathExtension().lastPathComponent
            result[stem] = result[stem] ?? url
        }

        if let playbackURL = filesByStem[MeetingAudioArchiveResolver.playbackStem] {
            return MeetingRetranscriptionInput(micURL: nil, systemURL: playbackURL)
        }

        if let importedURL = filesByStem[MeetingAudioArchiveResolver.importedStem] {
            return MeetingRetranscriptionInput(micURL: nil, systemURL: importedURL)
        }

        guard let systemURL = filesByStem[MeetingAudioArchiveResolver.systemStem] else {
            return nil
        }

        return MeetingRetranscriptionInput(
            micURL: filesByStem[MeetingAudioArchiveResolver.microphoneStem],
            systemURL: systemURL
        )
    }
}

enum MeetingAudioArchiveResolver {
    static let playbackStem = "playback"
    static let importedStem = "recording"
    static let systemStem = "system_audio"
    static let microphoneStem = "microphone"

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

        let liveURLs = [
            firstAudioFile(named: systemStem, in: regularFiles),
            firstAudioFile(named: microphoneStem, in: regularFiles)
        ].compactMap { $0 }
        let liveRetranscriptionURLs = liveURLs.isEmpty ? nil : liveURLs

        if let playbackURL = firstAudioFile(named: playbackStem, in: regularFiles) {
            return MeetingAudioAttachment(
                directoryURL: directoryURL,
                urls: [playbackURL],
                retranscriptionURLs: liveRetranscriptionURLs
            )
        }

        if let importedURL = firstAudioFile(named: importedStem, in: regularFiles) {
            return MeetingAudioAttachment(
                directoryURL: directoryURL,
                urls: [importedURL]
            )
        }

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

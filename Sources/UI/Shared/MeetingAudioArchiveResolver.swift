import Foundation

struct MeetingAudioPlaybackChoice: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let symbolName: String
    let urls: [URL]
}

struct MeetingAudioAttachment: Equatable, Sendable {
    let directoryURL: URL
    let urls: [URL]
    let retranscriptionURLs: [URL]

    init(directoryURL: URL, urls: [URL], retranscriptionURLs: [URL]? = nil) {
        self.directoryURL = directoryURL
        self.urls = urls
        self.retranscriptionURLs = retranscriptionURLs ?? urls
    }

    static func retainedAudio(urls: [URL]) -> MeetingAudioAttachment? {
        guard let firstURL = urls.first else { return nil }
        return MeetingAudioAttachment(
            directoryURL: firstURL.deletingLastPathComponent(),
            urls: urls
        )
    }

    var id: String {
        urls.map { $0.standardizedFileURL.path }.joined(separator: "|")
    }

    var playbackURLs: [URL] {
        defaultPlaybackChoice?.urls ?? []
    }

    var playbackURLCandidates: [[URL]] {
        playbackChoices.map(\.urls)
    }

    var playbackChoices: [MeetingAudioPlaybackChoice] {
        if urls.count <= 1 {
            return urls.map { playbackChoice(for: $0) }
        }

        if let splitChoice = splitStreamPlaybackChoice(in: urls) {
            return [splitChoice]
        }

        let preferredURLs = preferredAudioFiles(in: urls)
        if !preferredURLs.isEmpty {
            return preferredURLs.map { playbackChoice(for: $0) }
        }

        return urls.map { playbackChoice(for: $0) }
    }

    var defaultPlaybackChoice: MeetingAudioPlaybackChoice? {
        playbackChoices.first
    }

    func playbackChoice(id: String?) -> MeetingAudioPlaybackChoice? {
        guard let id else { return defaultPlaybackChoice }
        return playbackChoices.first { $0.id == id } ?? defaultPlaybackChoice
    }

    var isCompositePlayback: Bool {
        playbackURLs.count > 1
    }

    private func preferredAudioFiles(in urls: [URL]) -> [URL] {
        let preferredStems = ["playback", "recording", "system_audio", "microphone"]
        let preferredURLs = preferredStems.compactMap { firstAudioFile(named: $0, in: urls) }
        let preferredPaths = Set(preferredURLs.map { $0.standardizedFileURL.path })
        let remainingURLs = urls.filter { !preferredPaths.contains($0.standardizedFileURL.path) }
        return preferredURLs + remainingURLs
    }

    private func splitStreamPlaybackChoice(in urls: [URL]) -> MeetingAudioPlaybackChoice? {
        guard let systemURL = firstAudioFile(named: "system_audio", in: urls),
              firstAudioFile(named: "microphone", in: urls) != nil else {
            return nil
        }

        return playbackChoice(for: systemURL)
    }

    private func playbackChoice(for url: URL) -> MeetingAudioPlaybackChoice {
        let stem = url.deletingPathExtension().lastPathComponent
        let metadata = playbackChoiceMetadata(for: stem)
        return MeetingAudioPlaybackChoice(
            id: "\(stem):\(url.standardizedFileURL.path)",
            title: metadata.title,
            symbolName: metadata.symbolName,
            urls: [url]
        )
    }

    private func playbackChoiceMetadata(for stem: String) -> (title: String, symbolName: String) {
        switch stem {
        case "playback":
            return ("Mix", "waveform")
        case "recording":
            return ("Recording", "waveform")
        case "system_audio":
            return ("System", "speaker.wave.2.fill")
        case "microphone":
            return ("Mic", "mic.fill")
        default:
            return ("Audio", "waveform")
        }
    }

    private func firstAudioFile(named stem: String, in urls: [URL]) -> URL? {
        urls
            .filter { $0.deletingPathExtension().lastPathComponent == stem }
            .sorted { lhs, rhs in
                lhs.pathExtension.localizedCaseInsensitiveCompare(rhs.pathExtension) == .orderedAscending
            }
            .first
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

        let systemURL = firstAudioFile(named: systemStem, in: regularFiles)
        let microphoneURL = firstAudioFile(named: microphoneStem, in: regularFiles)
        let liveURLs = [systemURL, microphoneURL].compactMap { $0 }
        let splitRetranscriptionURLs: [URL]?
        if let systemURL, let microphoneURL {
            splitRetranscriptionURLs = [systemURL, microphoneURL]
        } else {
            splitRetranscriptionURLs = nil
        }

        if let playbackURL = firstAudioFile(named: playbackStem, in: regularFiles) {
            return MeetingAudioAttachment(
                directoryURL: directoryURL,
                urls: [playbackURL],
                retranscriptionURLs: splitRetranscriptionURLs
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

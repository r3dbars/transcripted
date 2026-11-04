import Foundation

public enum TranscriptAudioSource: String, Sendable, Equatable {
    case microphone = "mic"
    case systemAudio = "system_audio"
}

public struct TranscriptFormatOptions: Sendable, Equatable {
    public var audioSources: [TranscriptAudioSource]
    public var includeObsidianMetadata: Bool
    /// When an imported file was transcribed. Written as `imported_at` so the
    /// library can list the import where the user expects it (today), while
    /// `date:`/`time:` keep the original recording time.
    public var importedAt: Date?
    /// Written as `starred: true`. A replacement save sets it from the file it
    /// replaces (`TranscriptSaver.saveTranscript(targetURL:)`), so
    /// re-transcribing never drops a star.
    public var starred: Bool

    public init(
        audioSources: [TranscriptAudioSource] = [.microphone, .systemAudio],
        includeObsidianMetadata: Bool = false,
        importedAt: Date? = nil,
        starred: Bool = false
    ) {
        self.audioSources = Self.normalizedAudioSources(audioSources)
        self.includeObsidianMetadata = includeObsidianMetadata
        self.importedAt = importedAt
        self.starred = starred
    }

    public static let `default` = TranscriptFormatOptions()

    public func withAudioSources(_ sources: [TranscriptAudioSource]) -> TranscriptFormatOptions {
        TranscriptFormatOptions(
            audioSources: sources,
            includeObsidianMetadata: includeObsidianMetadata,
            importedAt: importedAt,
            starred: starred
        )
    }

    var includesMicrophone: Bool {
        audioSources.contains(.microphone)
    }

    var yamlSourcesList: String {
        audioSources.map(\.rawValue).joined(separator: ", ")
    }

    private static func normalizedAudioSources(_ sources: [TranscriptAudioSource]) -> [TranscriptAudioSource] {
        var result: [TranscriptAudioSource] = []
        for source in sources where !result.contains(source) {
            result.append(source)
        }
        return result.isEmpty ? [.systemAudio] : result
    }
}

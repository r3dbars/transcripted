import Foundation

public enum TranscriptAudioSource: String, Sendable, Equatable {
    case microphone = "mic"
    case systemAudio = "system_audio"
}

public struct TranscriptFormatOptions: Sendable, Equatable {
    public var audioSources: [TranscriptAudioSource]
    public var includeObsidianMetadata: Bool

    public init(
        audioSources: [TranscriptAudioSource] = [.microphone, .systemAudio],
        includeObsidianMetadata: Bool = false
    ) {
        self.audioSources = Self.normalizedAudioSources(audioSources)
        self.includeObsidianMetadata = includeObsidianMetadata
    }

    public static let `default` = TranscriptFormatOptions()

    public func withAudioSources(_ sources: [TranscriptAudioSource]) -> TranscriptFormatOptions {
        TranscriptFormatOptions(
            audioSources: sources,
            includeObsidianMetadata: includeObsidianMetadata
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

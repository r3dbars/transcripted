import Foundation

public enum TranscriptAudioSource: String, Sendable, Equatable {
    case microphone = "mic"
    case systemAudio = "system_audio"
}

public struct TranscriptFormatOptions: Sendable, Equatable {
    public var audioSources: [TranscriptAudioSource]

    public init(
        audioSources: [TranscriptAudioSource] = [.microphone, .systemAudio]
    ) {
        self.audioSources = Self.normalizedAudioSources(audioSources)
    }

    public static let `default` = TranscriptFormatOptions()

    public func withAudioSources(_ sources: [TranscriptAudioSource]) -> TranscriptFormatOptions {
        TranscriptFormatOptions(audioSources: sources)
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

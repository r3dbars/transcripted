import Combine
import Foundation
import TranscriptedCore

// Excluded collaborators only. Identity writes, snapshots, queue parsing and
// confirmation counts use production sources. Playback is never attempted.
enum MeetingStoragePaths {
    static var transcriptsFolder: URL { fatalError("Smoke must supply its transcript directory") }
}

@MainActor final class MeetingInviteeCalendarReader {
    static let shared = MeetingInviteeCalendarReader()
    func inviteeNames(recordingStart: Date) async -> [String] {
        fatalError("Smoke must not read Calendar")
    }
}

@MainActor final class SpeakerClipPlayback {
    static let shared = SpeakerClipPlayback()
    static func play(_ url: URL) { fatalError("Smoke must not play audio") }
    func play(_ sample: SpeakerRetainedAudioSample) { fatalError("Smoke must not play audio") }
}

// Clips are supplied for every synthetic profile, so retained-audio fallback
// must not run. Trap if the test accidentally asks for this excluded service.
struct MeetingAudioAttachment { let urls: [URL]; let retranscriptionURLs: [URL] }
enum MeetingAudioArchiveResolver {
    static let importedStem = "recording"
    static let systemStem = "system_audio"
    static let microphoneStem = "microphone"
    static let playbackStem = "playback"
    static func attachment(forTranscript: URL) -> MeetingAudioAttachment? {
        fatalError("Smoke must not resolve retained user audio")
    }
}

enum SpeakerSettingsMigrationPhase: Sendable, Equatable {
    struct Summary: Sendable, Equatable { let peopleNeedingConfirmation: Int }
    case idle
    case moving(completedPeople: Int, totalPeople: Int?)
    case finished(Summary)
    case failed(reason: String)
}
@MainActor struct SpeakerSettingsMigration {
    let phase: SpeakerSettingsMigrationPhase = .idle
    var phases: AnyPublisher<SpeakerSettingsMigrationPhase, Never> {
        Just(phase).eraseToAnyPublisher()
    }
}

enum AnalyticsReporter {
    static func countBucket(_ count: Int) -> String { "excluded" }
    static func track(_ event: String, properties: [String: String]) {
        fatalError("Smoke must not send analytics")
    }
}
@MainActor final class EventReporter {
    enum Level { case error }
    static let shared = EventReporter()
    func capture(level: Level, engine: String, event: String, message: String, context: [String: String]) {
        fatalError("Smoke must not send diagnostics")
    }
}

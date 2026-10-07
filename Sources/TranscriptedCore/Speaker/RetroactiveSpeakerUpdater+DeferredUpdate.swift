import Foundation

extension TranscriptSaver {

    enum DeferredSpeakerNameUpdateError: Error, LocalizedError, Equatable {
        case transcriptRestoreFailed(fileCount: Int)

        var errorDescription: String? {
            switch self {
            case .transcriptRestoreFailed(let count):
                return "Could not restore \(count) transcript(s) after the speaker update failed."
            }
        }
    }

    public struct DeferredSpeakerNameUpdate: Sendable {
        public let transcriptURL: URL
        public let dbId: UUID
        public let diarizerSpeakerId: String
        public let channel: UtteranceChannel

        public init(
            transcriptURL: URL,
            dbId: UUID,
            diarizerSpeakerId: String,
            channel: UtteranceChannel
        ) {
            self.transcriptURL = transcriptURL
            self.dbId = dbId
            self.diarizerSpeakerId = diarizerSpeakerId
            self.channel = channel
        }
    }
}

import Foundation
@testable import Transcripted

// MARK: - Test Fixtures

extension TranscriptionUtterance {
    static func mock(
        start: Double = 0.0,
        end: Double = 5.0,
        channel: Int = 0,
        speakerId: Int = 0,
        persistentSpeakerId: UUID? = nil,
        matchSimilarity: Double? = nil,
        transcript: String = "Hello world"
    ) -> TranscriptionUtterance {
        TranscriptionUtterance(
            start: start,
            end: end,
            channel: channel,
            speakerId: speakerId,
            persistentSpeakerId: persistentSpeakerId,
            matchSimilarity: matchSimilarity,
            transcript: transcript
        )
    }
}

extension TranscriptionResult {
    static func mock(
        micUtterances: [TranscriptionUtterance] = [],
        systemUtterances: [TranscriptionUtterance] = [],
        duration: TimeInterval = 60.0,
        processingTime: TimeInterval = 5.0
    ) -> TranscriptionResult {
        TranscriptionResult(
            micUtterances: micUtterances,
            systemUtterances: systemUtterances,
            duration: duration,
            processingTime: processingTime
        )
    }
}


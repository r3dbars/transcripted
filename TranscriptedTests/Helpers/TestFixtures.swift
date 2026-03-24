import Foundation
import Accelerate
@testable import Transcripted

// MARK: - Test Fixtures

@available(macOS 14.0, *)
extension SpeakerProfile {
    static func mock(
        id: UUID = UUID(),
        displayName: String? = nil,
        nameSource: String? = nil,
        embedding: [Float] = [1, 0, 0, 0],
        callCount: Int = 1,
        confidence: Double = 0.5
    ) -> SpeakerProfile {
        SpeakerProfile(
            id: id,
            displayName: displayName,
            nameSource: nameSource,
            embedding: embedding,
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: callCount,
            confidence: confidence,
            disputeCount: 0
        )
    }
}

// MARK: - Audio Sample Generators

enum TestAudioGenerator {
    /// Generate silence (all zeros)
    static func silence(duration: Double, sampleRate: Double = 16000) -> [Float] {
        [Float](repeating: 0.0, count: Int(duration * sampleRate))
    }

    /// Generate a sine wave tone
    static func tone(duration: Double, amplitude: Float = 0.5, frequency: Float = 440, sampleRate: Double = 16000) -> [Float] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { i in
            amplitude * sin(2.0 * .pi * frequency * Float(i) / Float(sampleRate))
        }
    }

    /// Generate speech-like pattern: alternating tone and silence
    static func speechLikePattern(
        speechDuration: Double = 2.0,
        silenceDuration: Double = 0.6,
        repetitions: Int = 3,
        amplitude: Float = 0.5,
        sampleRate: Double = 16000
    ) -> [Float] {
        var samples: [Float] = []
        for _ in 0..<repetitions {
            samples += tone(duration: speechDuration, amplitude: amplitude, sampleRate: sampleRate)
            samples += silence(duration: silenceDuration, sampleRate: sampleRate)
        }
        return samples
    }
}

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


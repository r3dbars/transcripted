import XCTest
@testable import TranscriptedCore

/// The pipeline measures the whole mic track once and hands that measurement to
/// silence splitting and language sampling. Promise: reusing it never changes
/// where speech is found, and a measurement of some other buffer is ignored.
@available(macOS 14.0, *)
final class SignalAnalysisReuseTests: XCTestCase {

    private let rate = 16_000

    /// Tone bursts at `amplitude` separated by near-silence, like turns of speech.
    private func bursts(amplitude: Float, pattern: [(speech: Double, gap: Double)]) -> [Float] {
        var out: [Float] = []
        var phase = 0
        for (speech, gap) in pattern {
            for _ in 0..<Int(speech * Double(rate)) {
                out.append(amplitude * Float(sin(Double(phase) * 2 * .pi * 220 / Double(rate))))
                phase += 1
            }
            for i in 0..<Int(gap * Double(rate)) {
                out.append(i.isMultiple(of: 2) ? 0.0002 : -0.0002)
            }
        }
        return out
    }

    private func bounds(_ segments: [Transcription.SpeechSegment]) -> [[Double]] {
        segments.map { [$0.start, $0.end] }
    }

    private var tracks: [[Float]] {
        [
            bursts(amplitude: 0.30, pattern: [(1.2, 0.6), (3.0, 1.0), (0.4, 0.5), (2.5, 0.2), (4.0, 0)]),
            bursts(amplitude: 0.02, pattern: [(2.0, 0.8), (0.7, 0.45), (5.0, 1.5), (1.0, 0)]),
            bursts(amplitude: 0.004, pattern: [(3.0, 0.5), (3.0, 0)]),
            [Float](repeating: 0, count: 3 * 16_000),
        ]
    }

    func testSilenceSplitIsTheSameWithTheTrackMeasuredOnce() {
        for samples in tracks {
            let analysis = AudioSignalRecovery.analyze(samples: samples, sampleRate: Double(rate))
            XCTAssertEqual(
                bounds(Transcription.detectSpeechSegments(samples: samples, sampleRate: Double(rate), analysis: analysis)),
                bounds(Transcription.detectSpeechSegments(samples: samples, sampleRate: Double(rate)))
            )
        }
    }

    func testAMeasurementOfAnotherBufferIsIgnored() {
        let loud = tracks[0]
        let quiet = tracks[1]
        let wrong = AudioSignalRecovery.analyze(samples: loud, sampleRate: Double(rate))
        XCTAssertEqual(
            bounds(Transcription.detectSpeechSegments(samples: quiet, sampleRate: Double(rate), analysis: wrong)),
            bounds(Transcription.detectSpeechSegments(samples: quiet, sampleRate: Double(rate)))
        )
        let wrongRate = AudioSignalRecovery.analyze(samples: quiet, sampleRate: 48_000)
        XCTAssertEqual(
            bounds(Transcription.detectSpeechSegments(samples: quiet, sampleRate: Double(rate), analysis: wrongRate)),
            bounds(Transcription.detectSpeechSegments(samples: quiet, sampleRate: Double(rate)))
        )
    }

    func testLanguageWindowsAreTheSameWithMeasuredTracks() {
        let all = tracks
        for (system, mic) in [(all[0], all[1]), (all[1], all[2]), (all[3], all[0]), ([], all[1])] {
            let micAnalysis = AudioSignalRecovery.analyze(samples: mic, sampleRate: Double(rate))
            XCTAssertEqual(
                Transcription.representativeLanguageSamples(tracks: [system, mic], analyses: [nil, micAnalysis]),
                Transcription.representativeLanguageSamples(tracks: [system, mic])
            )
        }
    }
}

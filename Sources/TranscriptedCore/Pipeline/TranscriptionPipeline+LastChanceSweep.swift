import Foundation
@preconcurrency import AVFoundation
import Accelerate
import FluidAudio

// MARK: - Last-Chance Speech Sweep

extension Transcription {

    /// One saved track for `lastChanceSpeechSweep` to look through again.
    struct LastChanceSweepTrack {
        enum Channel {
            case system
            case microphone
        }

        let url: URL
        let channel: Channel
    }

    struct LastChanceSweepResult {
        var systemUtterances: [TranscriptionUtterance] = []
        var micUtterances: [TranscriptionUtterance] = []
    }

    /// Speaker id for system-channel words the last-chance pass recovers. The
    /// diarizer found no speakers, so they belong to one unnamed remote
    /// speaker, labelled "Speaker 1" in the transcript.
    nonisolated static let lastChanceSystemSpeakerId = 1

    /// Gain cap for call-side audio in the last-chance pass. Call audio
    /// arrives at the call app's playback level, so boosting it as hard as a
    /// muffled mic (12x) mostly turns hold music, typing and room noise into
    /// something STT will try to read.
    private nonisolated static let lastChanceSystemMaxGain: Float = 3.0

    /// Words that on their own are not evidence anyone spoke to the meeting:
    /// STT emits them for breaths, clicks and music.
    private nonisolated static let lastChanceFillerWords: Set<String> = [
        "ah", "eh", "er", "hm", "hmm", "huh", "mhm", "mm", "mmm", "oh", "uh", "um", "uhm"
    ]

    /// Fewest non-filler words a channel must recover before the last-chance
    /// pass keeps any of them. Below this, "No speech found" (with a Try
    /// again button) is more honest than a transcript that says "Mm."
    private nonisolated static let lastChanceMinimumWords = 2

    /// Whether utterances recovered by the last-chance pass hold enough real
    /// words to be worth saving.
    nonisolated static func lastChanceRecoveredEnoughWords(_ utterances: [TranscriptionUtterance]) -> Bool {
        var words = 0
        for utterance in utterances {
            for token in utterance.transcript.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }) {
                guard !lastChanceFillerWords.contains(String(token)) else { continue }
                words += 1
                if words >= lastChanceMinimumWords { return true }
            }
        }
        return false
    }

    /// Runs right before the pipeline would report "No speech found", and on
    /// a split-mode mic whose diarized pass produced no words.
    ///
    /// The normal system pass only transcribes what the diarizer marks as
    /// speech, and its speech detector can miss quiet, distant or heavily
    /// compressed voices. This pass skips the diarizer: it reloads each track,
    /// splits it on silence and transcribes the pieces the way the default
    /// mic path does. Tracks that never get louder and quieter again (digital
    /// silence, steady hum, a DC offset) are skipped before any STT runs, so a
    /// truly empty recording still costs nothing and still fails the same way.
    /// A channel that yields only fillers or a single word is dropped, so
    /// noise that STT reads as "Mm." does not become a saved meeting.
    nonisolated static func lastChanceSpeechSweep(
        tracks: [LastChanceSweepTrack],
        parakeet: any SpeechToTextEngine,
        language: TranscriptionLanguageContext,
        droppedSegments: inout Int
    ) async throws -> LastChanceSweepResult {
        var result = LastChanceSweepResult()
        for track in tracks {
            try Task.checkCancellation()
            let channelName = track.channel == .system ? "system" : "microphone"
            let samples: [Float]
            do {
                samples = try AudioResampler.loadAndResample(url: track.url, targetRate: 16000)
            } catch {
                // The normal pass already loaded this track once, so a failure
                // here is not new information. Skip it rather than replace
                // the honest "no speech" outcome with an I/O error.
                AppLogger.transcription.warning("Last-chance pass could not reload a track", [
                    "channel": channelName,
                    "errorType": "\(type(of: error))"
                ])
                continue
            }
            guard AudioSignalRecovery.hasSpeechLikeModulation(samples: samples, sampleRate: 16000) else {
                AppLogger.transcription.info("Last-chance pass skipped a track with no speech-like signal", [
                    "channel": channelName
                ])
                continue
            }

            let segments = detectSpeechSegments(samples: samples, sampleRate: 16000)
            var recovered = 0
            for segment in segments {
                try Task.checkCancellation()
                let slice = AudioResampler.extractSlice(
                    from: samples,
                    sampleRate: 16000,
                    startTime: segment.start,
                    endTime: segment.end
                )
                guard let prepared = prepareMicSegmentForTranscription(
                    samples: slice,
                    sampleRate: 16000,
                    maxGain: track.channel == .system ? lastChanceSystemMaxGain : 12.0,
                    ignoringSpikes: true
                ),
                      AudioSignalRecovery.analyze(samples: prepared.samples, sampleRate: 16000).hasSpeechCandidate else {
                    droppedSegments += 1
                    continue
                }
                let text = try await parakeet.transcribeSegment(
                    samples: prepared.samples,
                    source: track.channel == .system ? .system : .microphone,
                    language: language
                )
                guard !text.isEmpty else { continue }
                recovered += 1
                switch track.channel {
                case .system:
                    result.systemUtterances.append(TranscriptionUtterance(
                        start: segment.start,
                        end: segment.end,
                        channel: 1,
                        speakerId: lastChanceSystemSpeakerId,
                        persistentSpeakerId: nil,
                        matchSimilarity: nil,
                        transcript: text
                    ))
                case .microphone:
                    result.micUtterances.append(TranscriptionUtterance(
                        start: segment.start,
                        end: segment.end,
                        channel: 0,
                        speakerId: 0,
                        persistentSpeakerId: nil,
                        matchSimilarity: nil,
                        transcript: text
                    ))
                }
            }
            AppLogger.transcription.info("Last-chance pass finished a track", [
                "channel": channelName,
                "segments": "\(segments.count)",
                "recovered": "\(recovered)"
            ])
        }
        if !lastChanceRecoveredEnoughWords(result.systemUtterances) {
            if !result.systemUtterances.isEmpty {
                AppLogger.transcription.info("Last-chance pass dropped filler-only call-side text")
            }
            result.systemUtterances = []
        }
        if !lastChanceRecoveredEnoughWords(result.micUtterances) {
            if !result.micUtterances.isEmpty {
                AppLogger.transcription.info("Last-chance pass dropped filler-only mic text")
            }
            result.micUtterances = []
        }
        return result
    }
}

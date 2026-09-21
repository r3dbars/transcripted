import Foundation

extension Transcription {
    /// Bounded acoustic evidence from the beginning, middle and end of voiced
    /// regions. Never repeats/overlaps time windows to manufacture agreement.
    /// The energy gate identifies candidates, not proof that audio is speech.
    nonisolated static func representativeLanguageSamples(tracks: [[Float]]) -> [[Float]] {
        struct Candidate {
            let track: Int
            let start: Int
            let end: Int
        }
        let rate = 16_000
        let maximum = 10 * rate
        let minimum = 2 * rate
        var candidates: [Candidate] = []
        for (track, samples) in tracks.enumerated() where samples.count >= minimum {
            let segments = detectSpeechSegments(samples: samples, sampleRate: Double(rate))
            for segment in segments {
                var start = max(0, Int(segment.start * Double(rate)))
                let end = min(samples.count, Int(segment.end * Double(rate)))
                while end - start >= minimum {
                    let stop = min(start + maximum, end)
                    candidates.append(Candidate(track: track, start: start, end: stop))
                    start = stop
                }
            }
        }
        candidates.sort { $0.start == $1.start ? $0.track < $1.track : $0.start < $1.start }
        guard !candidates.isEmpty else { return [] }
        // Search near three evenly spaced candidate positions. If a candidate
        // is silent/nonfinite or overlaps selected audio, try its neighbors.
        var selected: [Candidate] = []
        var windows: [[Float]] = []
        for anchor in [0, candidates.count / 2, candidates.count - 1] {
            let representedTracks = Set(selected.map(\.track))
            let indices = candidates.indices.sorted {
                let lhsRepresented = representedTracks.contains(candidates[$0].track)
                let rhsRepresented = representedTracks.contains(candidates[$1].track)
                if lhsRepresented != rhsRepresented { return !lhsRepresented }
                let lhs = abs($0 - anchor), rhs = abs($1 - anchor)
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
            for index in indices {
                let candidate = candidates[index]
                guard !selected.contains(where: {
                    candidate.start < $0.end && candidate.end > $0.start
                }) else { continue }
                let samples = Array(tracks[candidate.track][candidate.start..<candidate.end])
                guard samples.allSatisfy(\.isFinite),
                      AudioSignalRecovery.analyze(samples: samples, sampleRate: Double(rate)).hasSpeechCandidate else { continue }
                selected.append(candidate)
                windows.append(samples)
                break
            }
        }
        return windows
    }
}

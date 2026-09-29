// SpeakerVoiceprintMigrationPolicy.swift
// Pure decisions for carrying named people over to a new voiceprint model
// (`SpeakerVoiceprintMigration`): which stretches of a saved transcript belong
// to a person, how one session's pieces pool into one vector, and whether a
// person's re-embedded audio agrees with itself well enough to keep silent
// naming. No I/O, no clock, so tests can drive it with plain values.

import Foundation

public enum SpeakerVoiceprintMigrationPolicy {

    // MARK: - Transcript rows to audio ranges

    /// One row of a saved meeting transcript: when it starts, which track it came
    /// from, and the speaker label printed on it (wiki-link brackets removed).
    public struct TranscriptRow: Sendable, Equatable {
        public var start: Double
        public var channel: UtteranceChannel
        public var label: String

        public init(start: Double, channel: UtteranceChannel, label: String) {
            self.start = start
            self.channel = channel
            self.label = label
        }
    }

    /// A stretch of one audio track, in seconds from the start of that track.
    public struct TimeRange: Sendable, Equatable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }

        public var seconds: Double { max(0, end - start) }
    }

    /// How transcript rows become audio ranges.
    ///
    /// Saved transcripts keep only each row's start, floored to the second, so a
    /// row's real start is up to a second later than printed and its end is
    /// unknown. A range therefore starts `leadTrimSeconds` after the printed start
    /// (so the previous speaker's tail is never included) and ends where the next
    /// row on the same track starts (whose real start is at or after its printed
    /// second). The last row on a track gets `openEndSeconds`.
    public struct RangeLimits: Sendable, Equatable {
        public var leadTrimSeconds: Double
        /// Shorter stretches are dropped: too little voice to embed reliably.
        public var minSeconds: Double
        /// Longer stretches are cut into pieces of at most this length.
        public var maxSeconds: Double
        /// Length assumed for the last row on a track, which has no next row.
        public var openEndSeconds: Double
        /// Most speech taken from one meeting for one person (longest pieces first).
        public var maxTotalSeconds: Double

        public init(
            leadTrimSeconds: Double = 1.0,
            minSeconds: Double = 1.5,
            maxSeconds: Double = 15,
            openEndSeconds: Double = 8,
            maxTotalSeconds: Double = 60
        ) {
            self.leadTrimSeconds = leadTrimSeconds
            self.minSeconds = minSeconds
            self.maxSeconds = maxSeconds
            self.openEndSeconds = openEndSeconds
            self.maxTotalSeconds = maxTotalSeconds
        }
    }

    /// The stretches of `channel` audio where `labels` are talking, in time order,
    /// within `limits.maxTotalSeconds`. Consecutive rows by the same person on a
    /// track join into one stretch; rows on the other track never end a stretch,
    /// because each track is its own recording.
    public static func ranges(
        forLabels labels: Set<String>,
        on channel: UtteranceChannel,
        rows: [TranscriptRow],
        limits: RangeLimits = RangeLimits()
    ) -> [TimeRange] {
        guard !labels.isEmpty, limits.minSeconds > 0, limits.maxSeconds >= limits.minSeconds else { return [] }
        let track = rows.enumerated()
            .filter { $0.element.channel == channel && $0.element.start.isFinite && $0.element.start >= 0 }
            .sorted { lhs, rhs in
                lhs.element.start != rhs.element.start
                    ? lhs.element.start < rhs.element.start
                    : lhs.offset < rhs.offset
            }
            .map(\.element)

        var pieces: [TimeRange] = []
        var index = 0
        while index < track.count {
            guard labels.contains(track[index].label) else {
                index += 1
                continue
            }
            var last = index
            while last + 1 < track.count, labels.contains(track[last + 1].label) {
                last += 1
            }
            let runStart = track[index].start + limits.leadTrimSeconds
            let runEnd = last + 1 < track.count
                ? track[last + 1].start
                : track[last].start + limits.openEndSeconds
            var cursor = runStart
            while runEnd - cursor >= limits.minSeconds {
                let end = min(runEnd, cursor + limits.maxSeconds)
                pieces.append(TimeRange(start: cursor, end: end))
                cursor = end
            }
            index = last + 1
        }
        return limitedToBudget(pieces, limits: limits)
    }

    /// Longest pieces first until `maxTotalSeconds`, returned in time order. The
    /// last piece is shortened to fit when what is left is still long enough.
    static func limitedToBudget(_ pieces: [TimeRange], limits: RangeLimits) -> [TimeRange] {
        var remaining = limits.maxTotalSeconds
        var kept: [TimeRange] = []
        for piece in pieces.sorted(by: { lhs, rhs in
            lhs.seconds != rhs.seconds ? lhs.seconds > rhs.seconds : lhs.start < rhs.start
        }) {
            guard remaining >= limits.minSeconds else { break }
            if piece.seconds <= remaining {
                kept.append(piece)
                remaining -= piece.seconds
            } else {
                kept.append(TimeRange(start: piece.start, end: piece.start + remaining))
                remaining = 0
            }
        }
        return kept.sorted { $0.start < $1.start }
    }

    // MARK: - Pooling and the quality gate

    /// One embedded piece of audio and how many seconds of it there were.
    public struct Piece: Sendable, Equatable {
        public var embedding: [Float]
        public var seconds: Double

        public init(embedding: [Float], seconds: Double) {
            self.embedding = embedding
            self.seconds = seconds
        }
    }

    /// Talk-time-weighted mean of `pieces`, L2-normalized. Pieces whose size
    /// differs from the first, or that are not finite, are skipped; nil when
    /// nothing usable is left.
    public static func pooledMean(_ pieces: [Piece]) -> [Float]? {
        guard let dimension = pieces.first(where: { !$0.embedding.isEmpty })?.embedding.count else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        var used = 0
        for piece in pieces where piece.embedding.count == dimension && piece.seconds > 0 {
            guard piece.embedding.allSatisfy(\.isFinite) else { continue }
            let normalized = SpeakerVectorMath.l2Normalize(piece.embedding)
            let weight = Float(piece.seconds)
            for i in 0..<dimension {
                sum[i] += normalized[i] * weight
            }
            used += 1
        }
        guard used > 0, sum.contains(where: { $0 != 0 }) else { return nil }
        return SpeakerVectorMath.l2Normalize(sum)
    }

    /// What the new model makes of one person's carried-over audio.
    public struct Assessment: Sendable, Equatable {
        /// The new voiceprint: the mean of the sessions that agree (all sessions
        /// when they don't).
        public var centroid: [Float]
        /// The mean of each usable session (a meeting, or the saved review clip),
        /// in the order given.
        public var sessionMeans: [[Float]]
        /// Indices into `sessionMeans` that agree with the most typical session.
        public var agreeingSessions: [Int]
        /// Median cosine between sessions, or between the two halves of the only
        /// session; nil when there was a single piece and nothing to compare.
        public var selfSimilarity: Double?
        /// True when the audio agrees with itself: more than half the sessions
        /// (and at least two) clear the bar, or the only session's two halves do.
        public var isConsistent: Bool
    }

    /// Decide whether `sessions` (each a list of embedded pieces) sound like one
    /// person under the new model. `agreementBar` is the lowest cosine two means
    /// of the same person should reach; callers pass the new model's
    /// `matchManySegments`, the bar at which two well-backed means match across
    /// calls. Returns nil when no session produced a usable vector.
    ///
    /// Several sessions: the medoid (the session with the highest median cosine to
    /// the others) anchors the check; sessions within `agreementBar` of it agree.
    /// A strict majority (at least two) must agree. One session: its pieces are
    /// split into alternating halves and the halves must agree. One piece: nothing
    /// can be checked, so the result is not consistent.
    public static func assess(sessions: [[Piece]], agreementBar: Double) -> Assessment? {
        let means = sessions.compactMap { pooledMean($0) }
        guard let first = means.first else { return nil }
        let dimension = first.count
        let usableMeans = means.filter { $0.count == dimension }
        let usableSessions = sessions.filter { pooledMean($0)?.count == dimension }

        if usableMeans.count >= 2 {
            let count = usableMeans.count
            var cosines = Array(repeating: Array(repeating: 1.0, count: count), count: count)
            var pairwise: [Double] = []
            for i in 0..<count {
                for j in (i + 1)..<count {
                    let cosine = SpeakerVectorMath.cosineSimilarity(usableMeans[i], usableMeans[j])
                    cosines[i][j] = cosine
                    cosines[j][i] = cosine
                    pairwise.append(cosine)
                }
            }
            var medoid = 0
            var medoidScore = -Double.infinity
            for i in 0..<count {
                let score = median((0..<count).filter { $0 != i }.map { cosines[i][$0] })
                if score > medoidScore {
                    medoidScore = score
                    medoid = i
                }
            }
            let agreeing = (0..<count).filter { $0 == medoid || cosines[medoid][$0] >= agreementBar }
            let consistent = agreeing.count >= 2 && agreeing.count * 2 > count
            let centroidSources = consistent ? agreeing.map { usableMeans[$0] } : usableMeans
            let centroid = pooledMean(centroidSources.map { Piece(embedding: $0, seconds: 1) }) ?? first
            return Assessment(
                centroid: centroid,
                sessionMeans: usableMeans,
                agreeingSessions: consistent ? agreeing : [],
                selfSimilarity: median(pairwise),
                isConsistent: consistent
            )
        }

        let pieces = (usableSessions.first ?? []).filter { $0.embedding.count == dimension && $0.seconds > 0 }
        guard pieces.count >= 2 else {
            return Assessment(
                centroid: first,
                sessionMeans: [first],
                agreeingSessions: [],
                selfSimilarity: nil,
                isConsistent: false
            )
        }
        let even = pieces.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let odd = pieces.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        guard let evenMean = pooledMean(even), let oddMean = pooledMean(odd) else {
            return Assessment(
                centroid: first,
                sessionMeans: [first],
                agreeingSessions: [],
                selfSimilarity: nil,
                isConsistent: false
            )
        }
        let halves = SpeakerVectorMath.cosineSimilarity(evenMean, oddMean)
        let consistent = halves >= agreementBar
        return Assessment(
            centroid: first,
            sessionMeans: [first],
            agreeingSessions: consistent ? [0] : [],
            selfSimilarity: halves,
            isConsistent: consistent
        )
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

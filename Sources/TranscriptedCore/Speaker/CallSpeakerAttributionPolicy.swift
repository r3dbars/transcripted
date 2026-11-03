import Foundation

/// Names diarized call-audio voices from what the call app showed about who
/// was talking (`CallSpeakerActivity`). Pure: no I/O, no logging, no clock.
///
/// A voice gets a name only when the evidence clearly points at one person:
/// 1. Intervals of the local user (`selfNames`) are ignored; the user is the
///    mic track.
/// 2. Evidence is time where exactly one other participant was shown as
///    speaking. Two or more at once is ambiguous and skipped.
/// 3. Per voice, the seconds its speech overlaps each name's evidence are
///    summed. The best name wins when it has at least `minEvidenceSeconds`,
///    holds at least `minShare` of all overlapped evidence, and the evidence
///    covers at least `minCoveredFraction` of the voice's speech.
/// 4. The policy may give one name to several voices (the diarizer split one
///    person) when each passes on its own, but the pipeline then withholds
///    all of them (`nameShared`), and also any voice whose name another
///    voice already shows: body labels are `[System/<name>]`, so two voices
///    under one name can't be told apart and a rename would hit both
///    (`TranscriptionTaskManager.applyCallSpeakerNames`).
/// 5. Roster-only observations never name a voice. Visible tiles do not prove
///    a complete participant roster or successful self identification; even
///    one observed name and one voice can belong to different people.
/// 6. Anything else is withheld, with a reason for counts-only logging.
///
/// When `activity.coverage` is non-empty, intervals are clipped to it, since
/// outside a trustworthy read there is no evidence either way.
///
/// Names are compared trimmed, whitespace-collapsed and case-insensitively;
/// the output uses the spelling seen most often. Names are user content:
/// callers must never log them.
public enum CallSpeakerAttributionPolicy {
    public struct Thresholds: Sendable, Equatable {
        public var minEvidenceSeconds: Double
        public var minShare: Double
        public var minCoveredFraction: Double

        public init(
            minEvidenceSeconds: Double = 3.0,
            minShare: Double = 0.7,
            minCoveredFraction: Double = 0.2
        ) {
            self.minEvidenceSeconds = minEvidenceSeconds
            self.minShare = minShare
            self.minCoveredFraction = minCoveredFraction
        }

        public static let `default` = Thresholds()
    }

    /// One stretch of a diarized voice's speech, in seconds from recording start.
    public struct SpeechSpan: Sendable, Equatable {
        public let start: Double
        public let end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    /// Why a voice got no name. Safe to log and count; carries no names.
    public enum WithheldReason: String, Sendable, Equatable, CaseIterable {
        /// None of the voice's speech overlapped single-speaker evidence.
        case noEvidence = "no_evidence"
        /// The best name overlapped less than `minEvidenceSeconds`.
        case tooLittleEvidence = "too_little_evidence"
        /// The best name held less than `minShare` of the overlapped evidence.
        case namesDisagree = "names_disagree"
        /// Evidence covered less than `minCoveredFraction` of the voice's speech.
        case lowCoverage = "low_coverage"
        /// Legacy reason retained for API compatibility; roster-only reads now yield `noEvidence`.
        case rosterNotSingle = "roster_not_single"
        /// Legacy reason retained for API compatibility; roster-only reads now yield `noEvidence`.
        case voicesNotSingle = "voices_not_single"
        /// Another call-audio voice in the meeting shows, or would show, the
        /// same name. Set by the pipeline after the policy, never by `attribute`.
        case nameShared = "name_shared"
    }

    public struct Outcome: Sendable, Equatable {
        /// Diarizer voice id to participant name, as the call app spelled it.
        public var names: [String: String]
        /// Diarizer voice id to why it got no name.
        public var withheld: [String: WithheldReason]

        public init(names: [String: String] = [:], withheld: [String: WithheldReason] = [:]) {
            self.names = names
            self.withheld = withheld
        }
    }

    public static func attribute(
        activity: CallSpeakerActivity,
        clusters: [String: [SpeechSpan]],
        thresholds: Thresholds = .default
    ) -> Outcome {
        guard !clusters.isEmpty else { return Outcome() }

        let selfKeys = Set(activity.selfNames.map(normalizedKey))
        let spellings = preferredSpellings(activity: activity, excluding: selfKeys)

        guard activity.sawSpeakingIndicator else {
            return Outcome(withheld: clusters.mapValues { _ in .noEvidence })
        }

        let evidence = singleSpeakerEvidence(activity: activity, selfKeys: selfKeys)
        var outcome = Outcome()
        for (clusterId, spans) in clusters {
            let speech = mergedSpans(spans.map { ($0.start, $0.end) })
            let totalSpeech = speech.reduce(0) { $0 + ($1.end - $1.start) }

            var overlapByKey: [String: Double] = [:]
            for piece in evidence {
                let overlap = overlapSeconds(speech, piece.start, piece.end)
                if overlap > 0 { overlapByKey[piece.key, default: 0] += overlap }
            }
            let evidenceTotal = overlapByKey.values.reduce(0, +)
            guard evidenceTotal > 0 else {
                outcome.withheld[clusterId] = .noEvidence
                continue
            }
            // Highest overlap; ties break on the key so the result is stable.
            let best = overlapByKey.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            }!
            if best.value < thresholds.minEvidenceSeconds {
                outcome.withheld[clusterId] = .tooLittleEvidence
            } else if best.value / evidenceTotal < thresholds.minShare {
                outcome.withheld[clusterId] = .namesDisagree
            } else if evidenceTotal < thresholds.minCoveredFraction * totalSpeech {
                outcome.withheld[clusterId] = .lowCoverage
            } else {
                outcome.names[clusterId] = spellings[best.key] ?? best.key
            }
        }
        return outcome
    }

    // MARK: - Evidence

    private struct EvidencePiece {
        let key: String
        let start: Double
        let end: Double
    }

    /// Spans where exactly one non-self participant was shown speaking.
    private static func singleSpeakerEvidence(
        activity: CallSpeakerActivity,
        selfKeys: Set<String>
    ) -> [EvidencePiece] {
        let coverage = mergedSpans(activity.coverage.map { ($0.start, $0.end) })
        var rawByKey: [String: [(start: Double, end: Double)]] = [:]
        for interval in activity.intervals {
            let key = normalizedKey(interval.name)
            guard !key.isEmpty, !selfKeys.contains(key), interval.end > interval.start else { continue }
            if coverage.isEmpty {
                rawByKey[key, default: []].append((interval.start, interval.end))
            } else {
                for span in coverage {
                    let start = max(span.start, interval.start)
                    let end = min(span.end, interval.end)
                    if end > start { rawByKey[key, default: []].append((start, end)) }
                }
            }
        }
        // One person's own overlapping intervals are one person, not two.
        let byKey = rawByKey.mapValues { mergedSpans($0) }

        var boundaries: [Double] = []
        for spans in byKey.values {
            for span in spans {
                boundaries.append(span.start)
                boundaries.append(span.end)
            }
        }
        boundaries = Array(Set(boundaries)).sorted()
        guard boundaries.count >= 2 else { return [] }

        var pieces: [EvidencePiece] = []
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            let middle = (start + end) / 2
            var activeKey: String?
            var activeCount = 0
            for (key, spans) in byKey where spans.contains(where: { $0.start <= middle && middle < $0.end }) {
                activeKey = key
                activeCount += 1
                if activeCount > 1 { break }
            }
            if activeCount == 1, let activeKey {
                pieces.append(EvidencePiece(key: activeKey, start: start, end: end))
            }
        }
        return pieces
    }

    // MARK: - Names

    /// Trimmed, whitespace-collapsed, case-folded.
    static func normalizedKey(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    /// For each normalized name, the spelling seen most often (ties: the
    /// lexically first spelling, so the result doesn't depend on order).
    private static func preferredSpellings(
        activity: CallSpeakerActivity,
        excluding selfKeys: Set<String>
    ) -> [String: String] {
        var counts: [String: [String: Int]] = [:]
        let seen = activity.intervals.map(\.name) + activity.rosterNames
        for raw in seen {
            let key = normalizedKey(raw)
            guard !key.isEmpty, !selfKeys.contains(key) else { continue }
            let spelling = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            counts[key, default: [:]][spelling, default: 0] += 1
        }
        return counts.mapValues { spellings in
            spellings.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            }!.key
        }
    }

    // MARK: - Span math

    private static func mergedSpans(_ spans: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
        let sorted = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [(start: Double, end: Double)] = []
        for span in sorted {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private static func overlapSeconds(
        _ spans: [(start: Double, end: Double)],
        _ start: Double,
        _ end: Double
    ) -> Double {
        spans.reduce(0) { total, span in
            total + max(0, min(span.end, end) - max(span.start, start))
        }
    }
}

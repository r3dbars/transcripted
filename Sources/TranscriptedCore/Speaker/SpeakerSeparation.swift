// SpeakerSeparation.swift
// "Split generously, then merge smartly" for the call (system audio) channel.
//
// The shipped diarizer settings were tuned on 16 two-person calls. In the YODAS3
// speaker lab (Tools/SpeakerEvalHarness/YODAS_LAB_RESULTS.md) they merge people on
// bigger calls: a 7-person call comes back as ~4 voices and about half the words
// land under the wrong person. A merged voice can never get one right name.
//
// These options let the diarizer split more (a higher clustering threshold) and
// then clean up the extra pieces with evidence the diarizer does not use:
//   1. fold voices with almost no talk time into the voice they sound most like,
//      when they sound enough like it
//   2. merge voices whose fingerprints are close
//   3. if the calendar invite says how many people were on the call, fold the
//      quietest voices that sound like someone else until the count fits
// A voice that doesn't sound like anyone left stays its own speaker: an extra
// row costs one review click, but two people under one name can't be split.
// On for every meeting. The app picks the options per meeting through
// `TranscriptionTaskManager.speakerSeparationProvider` (`tuned(for:invitedPeople:)`).

import Foundation

public struct SpeakerSeparationOptions: Sendable, Equatable {
    /// Offline diarizer clustering threshold. Higher splits more. nil keeps the
    /// shipped setting (0.6).
    public var clusteringThreshold: Double?
    /// Voices with less total talk time than this (seconds) are folded into the
    /// voice they sound most like. nil turns the fold off.
    public var foldBelowSeconds: Double?
    /// A short voice is folded only when its fingerprint is at least this similar
    /// (cosine) to the voice it would join; otherwise it stays its own speaker. A
    /// short voice with no fingerprint is never folded. nil folds into the closest
    /// fingerprint with no floor.
    public var foldSimilarity: Double?
    /// Voices whose fingerprints are at least this similar (cosine) are merged.
    /// nil turns the merge off.
    public var mergeSimilarity: Double?
    /// At most this many voices on the call channel (from the calendar invite).
    /// nil means no cap.
    public var maxSpeakers: Int?
    /// The cap folds a voice only when its fingerprint is at least this similar
    /// (cosine) to the voice it would join; a voice that clears nobody stays even
    /// if that leaves more voices than the cap. nil folds regardless (a voice with
    /// no fingerprint joins the one that talked most).
    public var capFoldSimilarity: Double?

    public init(
        clusteringThreshold: Double? = nil,
        foldBelowSeconds: Double? = nil,
        foldSimilarity: Double? = nil,
        mergeSimilarity: Double? = nil,
        maxSpeakers: Int? = nil,
        capFoldSimilarity: Double? = nil
    ) {
        self.clusteringThreshold = clusteringThreshold
        self.foldBelowSeconds = foldBelowSeconds
        self.foldSimilarity = foldSimilarity
        self.mergeSimilarity = mergeSimilarity
        self.maxSpeakers = maxSpeakers
        self.capFoldSimilarity = capFoldSimilarity
    }

    /// The settings the speaker lab picked: split at 0.70, fold voices under 5 s,
    /// merge fingerprints at the voiceprint model's `separationMerge` and up (0.6 for
    /// WeSpeaker), and cap at the invite size when there is one. The 0.70 is the
    /// diarizer's own clustering setting, not a voiceprint bar. The fold and cap
    /// bars are the same as Nemotron's (see `nemotronTuned`).
    public static func labTuned(
        maxSpeakers: Int?,
        thresholds: SpeakerEmbeddingThresholds = .weSpeaker
    ) -> SpeakerSeparationOptions {
        SpeakerSeparationOptions(
            clusteringThreshold: 0.70,
            foldBelowSeconds: 5.0,
            foldSimilarity: Double(thresholds.microAbsorb),
            mergeSimilarity: thresholds.separationMerge,
            maxSpeakers: maxSpeakers,
            capFoldSimilarity: thresholds.separationMerge
        )
    }

    /// Settings for the Nemotron backend, picked in the speaker lab. Nemotron already
    /// tells people apart well and has no clustering threshold, and a fingerprint
    /// merge only cost it people, so: fold voices under 5 s, and cap at one voice
    /// only when the invite is a one-on-one (a bigger invite's cap folded real people
    /// who talked little).
    ///
    /// Both folds need the voices to sound alike. A short voice joins another only at
    /// the voiceprint model's `microAbsorb` bar (the clusterer's bar for absorbing a
    /// very short cluster, 0.62 for WeSpeaker), so a real line from someone else stays
    /// theirs. The one-on-one cap folds only at `separationMerge` (the bar that says
    /// two call voices are one person), so a third person, or a different call during a
    /// recurring one-on-one's slot, isn't collapsed into the invitee.
    public static func nemotronTuned(
        invitedPeople: Int?,
        thresholds: SpeakerEmbeddingThresholds = .weSpeaker
    ) -> SpeakerSeparationOptions {
        SpeakerSeparationOptions(
            foldBelowSeconds: 5.0,
            foldSimilarity: Double(thresholds.microAbsorb),
            maxSpeakers: invitedPeople == 1 ? 1 : nil,
            capFoldSimilarity: thresholds.separationMerge
        )
    }

    /// The tuned settings for `backend`, capped from the invite size when there is one.
    /// `thresholds` is the active voiceprint model's set (the diarizer's
    /// `activeSpeakerThresholds`), which supplies the fingerprint merge bar.
    public static func tuned(
        for backend: DiarizationBackend,
        invitedPeople: Int?,
        thresholds: SpeakerEmbeddingThresholds = .weSpeaker
    ) -> SpeakerSeparationOptions {
        switch backend {
        case .nemotron:
            return nemotronTuned(invitedPeople: invitedPeople, thresholds: thresholds)
        case .pyannote:
            return labTuned(
                maxSpeakers: invitedPeople.flatMap { speakerCap(invitedPeople: $0) },
                thresholds: thresholds
            )
        }
    }

    /// Speaker cap from a calendar invite: the invited people (you excluded), plus
    /// one spare seat on calls of three or more for someone who joins uninvited.
    /// nil when the invite lists nobody.
    public static func speakerCap(invitedPeople: Int) -> Int? {
        guard invitedPeople > 0 else { return nil }
        return invitedPeople + (invitedPeople >= 3 ? 1 : 0)
    }
}

public enum SpeakerSeparation {
    /// Relabels diarizer segments so that folded and merged voices share one
    /// speaker id. Segment times, embeddings, and order are unchanged. The
    /// surviving id of a merge is always the voice with more talk time.
    public static func apply(_ segments: [SpeakerSegment], options: SpeakerSeparationOptions) -> [SpeakerSegment] {
        var voices = voiceSummaries(segments)
        guard voices.count >= 2 else { return segments }
        var survivor: [Int: Int] = Dictionary(uniqueKeysWithValues: voices.keys.map { ($0, $0) })

        func fold(_ source: Int, into target: Int) {
            guard let a = voices[source], let b = voices[target] else { return }
            voices[target] = Voice(
                seconds: a.seconds + b.seconds,
                embedding: combined(a, b)
            )
            voices[source] = nil
            for (raw, current) in survivor where current == source {
                survivor[raw] = target
            }
        }

        // 1. Fold near-silent voices that sound like someone, quietest first.
        if let floor = options.foldBelowSeconds {
            for id in voices.keys.sorted(by: { order(voices, $0, $1) }) {
                guard voices.count >= 2, let voice = voices[id], voice.seconds < floor else { continue }
                if let target = closestVoice(
                    to: id,
                    in: voices,
                    minimumSimilarity: options.foldSimilarity,
                    unfingerprintedJoinsLoudest: false
                ) {
                    fold(id, into: target)
                }
            }
        }

        // 2. Merge the most similar pair while it clears the bar.
        if let bar = options.mergeSimilarity {
            while voices.count >= 2 {
                var best: (similarity: Double, a: Int, b: Int)?
                let ids = voices.keys.sorted()
                for i in 0..<ids.count {
                    for j in (i + 1)..<ids.count {
                        guard let ea = voices[ids[i]]?.embedding, let eb = voices[ids[j]]?.embedding else { continue }
                        let similarity = Transcription.cosineSimilarityStatic(ea, eb)
                        if best == nil || similarity > best!.similarity {
                            best = (similarity, ids[i], ids[j])
                        }
                    }
                }
                guard let pair = best, pair.similarity >= bar else { break }
                let (small, large) = order(voices, pair.a, pair.b) ? (pair.a, pair.b) : (pair.b, pair.a)
                fold(small, into: large)
            }
        }

        // 3. Calendar cap: fold the quietest voice that sounds like someone until
        //    the count fits. Voices that clear nobody's bar stay.
        if let cap = options.maxSpeakers {
            capLoop: while voices.count > max(1, cap) {
                for id in voices.keys.sorted(by: { order(voices, $0, $1) }) {
                    if let target = closestVoice(
                        to: id,
                        in: voices,
                        minimumSimilarity: options.capFoldSimilarity,
                        unfingerprintedJoinsLoudest: options.capFoldSimilarity == nil
                    ) {
                        fold(id, into: target)
                        continue capLoop
                    }
                }
                break
            }
        }

        guard survivor.contains(where: { $0.key != $0.value }) else { return segments }
        return segments.map { segment in
            let id = survivor[segment.speakerId] ?? segment.speakerId
            guard id != segment.speakerId else { return segment }
            return SpeakerSegment(
                speakerId: id,
                startTime: segment.startTime,
                endTime: segment.endTime,
                embedding: segment.embedding,
                qualityScore: segment.qualityScore
            )
        }
    }

    // MARK: - Internals

    struct Voice {
        var seconds: Double
        /// Unit-length, talk-time-weighted mean fingerprint, or nil when no
        /// segment of this voice carried one.
        var embedding: [Float]?
    }

    /// Per-voice talk time and fingerprint. Fingerprints come from segments at
    /// quality >= 0.3 and >= 1 s (the same filter the clusterer uses), falling back
    /// to every embedded segment when none pass.
    static func voiceSummaries(_ segments: [SpeakerSegment]) -> [Int: Voice] {
        var seconds: [Int: Double] = [:]
        var good: [Int: [([Float], Double)]] = [:]
        var any: [Int: [([Float], Double)]] = [:]
        for segment in segments {
            seconds[segment.speakerId, default: 0] += segment.duration
            guard let embedding = segment.embedding, !embedding.isEmpty else { continue }
            any[segment.speakerId, default: []].append((embedding, segment.duration))
            if segment.qualityScore >= 0.3, segment.duration >= 1.0 {
                good[segment.speakerId, default: []].append((embedding, segment.duration))
            }
        }
        var voices: [Int: Voice] = [:]
        for (id, total) in seconds {
            let source = good[id] ?? any[id] ?? []
            voices[id] = Voice(seconds: total, embedding: weightedMean(source))
        }
        return voices
    }

    static func weightedMean(_ items: [([Float], Double)]) -> [Float]? {
        guard let dimension = items.first?.0.count, dimension > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        for (embedding, weight) in items where embedding.count == dimension {
            let w = Float(max(weight, 1e-3))
            for k in 0..<dimension { sum[k] += embedding[k] * w }
        }
        return normalized(sum)
    }

    static func combined(_ a: Voice, _ b: Voice) -> [Float]? {
        switch (a.embedding, b.embedding) {
        case let (ea?, eb?) where ea.count == eb.count:
            return weightedMean([(ea, a.seconds), (eb, b.seconds)])
        case let (ea?, nil): return ea
        case let (nil, eb?): return eb
        default: return nil
        }
    }

    static func normalized(_ v: [Float]) -> [Float]? {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return v.map { $0 / norm }
    }

    /// The voice `id` sounds most like, or nil when it clears nobody.
    /// `minimumSimilarity` is the cosine the best match must reach (nil: no floor).
    /// With `unfingerprintedJoinsLoudest`, a voice that has no fingerprint, or no
    /// fingerprinted voice to compare with, goes to the voice with the most talk
    /// time; without it, it clears nobody. Ties break toward the lower id.
    static func closestVoice(
        to id: Int,
        in voices: [Int: Voice],
        minimumSimilarity: Double?,
        unfingerprintedJoinsLoudest: Bool
    ) -> Int? {
        let others = voices.keys.filter { $0 != id }.sorted()
        guard !others.isEmpty else { return nil }
        if let embedding = voices[id]?.embedding {
            let scored = others.compactMap { other -> (Double, Int)? in
                guard let e = voices[other]?.embedding else { return nil }
                return (Transcription.cosineSimilarityStatic(embedding, e), other)
            }
            if let best = scored.max(by: { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 > $1.1) }) {
                if let minimumSimilarity, best.0 < minimumSimilarity { return nil }
                return best.1
            }
        }
        guard unfingerprintedJoinsLoudest else { return nil }
        return others.max { (voices[$0]?.seconds ?? 0, -$0) < (voices[$1]?.seconds ?? 0, -$1) }
    }

    /// Quieter first; ties break toward the higher id so results are stable.
    static func order(_ voices: [Int: Voice], _ a: Int, _ b: Int) -> Bool {
        let sa = voices[a]?.seconds ?? 0
        let sb = voices[b]?.seconds ?? 0
        return sa != sb ? sa < sb : a > b
    }
}

import Foundation
@preconcurrency import AVFoundation
import Accelerate
import FluidAudio

// MARK: - Mic Channel Diarization

extension Transcription {


    /// Result of running diarization + classification on the mic channel.
    struct MicChannelResult {
        let utterances: [TranscriptionUtterance]
        let speakerContexts: [String: ChannelSpeakerContext]
        let newlyCreatedProfileIds: Set<UUID>
    }

    struct GhostSpeakerMergeCandidate: Equatable {
        let speakerId: Int
        let similarity: Double
    }

    /// Collapse `a → b → c` remap chains so every key maps directly to its
    /// terminal target.
    ///
    /// Both diarization paths build their remap in two passes — ghost merge
    /// first, cross-cluster link second — and the second can retarget a key the
    /// first already pointed at. Every consumer resolves with a single
    /// dictionary lookup, so the chain has to be flattened here rather than at
    /// each read site. The chain is provably two hops today; the visited set is
    /// there so a future third pass cannot turn a cycle into a hang.
    nonisolated static func resolvingRemapChains(_ remap: [Int: Int]) -> [Int: Int] {
        var resolved: [Int: Int] = [:]
        resolved.reserveCapacity(remap.count)
        for (source, firstTarget) in remap {
            var target = firstTarget
            var visited: Set<Int> = [source]
            while let next = remap[target], !visited.contains(target) {
                visited.insert(target)
                target = next
            }
            resolved[source] = target
        }
        return resolved
    }

    /// Ghost speakers only have a best-effort embedding from segments that were
    /// too short, low-quality, or contaminated for normal profile matching. Keep
    /// the auto-merge floor high enough that uncertain voices survive to review:
    /// callers compare against the active model's
    /// `SpeakerEmbeddingThresholds.ghostMergeFloor`.
    nonisolated static func bestGhostSpeakerMergeCandidate(
        for meanEmbedding: [Float],
        nonGhostMeans: [Int: [Float]]
    ) -> GhostSpeakerMergeCandidate? {
        var bestCandidate: GhostSpeakerMergeCandidate?
        for (otherId, otherMean) in nonGhostMeans {
            let similarity = cosineSimilarityStatic(meanEmbedding, otherMean)
            guard bestCandidate == nil || similarity > bestCandidate!.similarity else { continue }
            bestCandidate = GhostSpeakerMergeCandidate(speakerId: otherId, similarity: similarity)
        }
        return bestCandidate
    }

    /// Diarize + transcribe the mic channel when local-speaker split is on.
    /// Mirrors the system-audio classification path but skips the cross-channel
    /// contamination gate (there's nothing to gate against inside mic processing itself).
    /// Uses the pre-run `existingProfiles` snapshot so both channels match against
    /// the same stable set of DB profiles.
    nonisolated static func processMicChannelWithDiarization(
        samples: [Float],
        diarization: any DiarizationEngine,
        parakeet: any SpeechToTextEngine,
        speakerDB: any SpeakerStore,
        existingProfiles: [SpeakerProfile],
        droppedSegments: inout Int,
        language: TranscriptionLanguageContext = .init(selection: .automatic, languageCode: nil, resolution: .unsupported),
        onProgress: ((Double) -> Void)?
    ) async throws -> MicChannelResult {

        AppLogger.transcription.info("Running offline diarization on mic audio")
        let rawSegments = try await diarization.diarizeOffline(samples: samples, sampleRate: 16000)

        let speakerThresholds = diarization.activeSpeakerThresholds
        let speakerSegments = EmbeddingClusterer.postProcess(
            segments: rawSegments,
            existingProfiles: existingProfiles,
            pairwiseMergeThreshold: nil,
            consolidationThreshold: speakerThresholds.consolidation,
            thresholds: speakerThresholds
        )

        let rawSpeakerCount = Set(rawSegments.map { $0.speakerId }).count
        let postProcessedSpeakerCount = Set(speakerSegments.map { $0.speakerId }).count
        AppLogger.transcription.info("Post-processed mic speaker segments", [
            "diarizer": "\(rawSpeakerCount)",
            "after": "\(postProcessedSpeakerCount)",
            "segments": "\(speakerSegments.count)"
        ])

        // Finish every throwing/cancellable mic operation before mutating the
        // speaker database. If mic STT fails after the system channel already
        // succeeded, the caller can safely keep the system-only transcript
        // without leaving partial mic speaker profiles behind.
        var transcribedSegments: [(segment: SpeakerSegment, text: String)] = []
        let totalSegments = speakerSegments.count
        for (index, segment) in speakerSegments.enumerated() {
            try Task.checkCancellation()

            let segmentSamples = AudioResampler.extractSlice(
                from: samples,
                sampleRate: 16000,
                startTime: segment.startTime,
                endTime: segment.endTime
            )
            guard let preparedSegment = Self.prepareMicSegmentForTranscription(
                samples: segmentSamples,
                sampleRate: 16000
            ) else {
                droppedSegments += 1
                continue
            }

            let text = try await parakeet.transcribeSegment(
                samples: preparedSegment.samples,
                source: .microphone,
                language: language
            )
            guard !text.isEmpty else {
                var context = preparedSegment.analysis.context
                context["segment_index"] = "\(index)"
                context["gain"] = String(format: "%.2f", preparedSegment.gain)
                context["padded_samples"] = "\(preparedSegment.paddedSampleCount)"
                AppLogger.transcription.warning("Mic diarization segment returned empty transcription", context)
                continue
            }

            transcribedSegments.append((segment: segment, text: text))
            let progress = 0.65 + (Double(index + 1) / Double(max(1, totalSegments))) * 0.25
            onProgress?(progress)
        }
        try Task.checkCancellation()

        // Aggregate embeddings per diarizer speaker ID. Same quality gates as the system
        // path (>=0.3 quality, >=1.0s duration). No cross-channel contamination gate —
        // codex review flagged symmetric weighting as a recall killer for normal cross-talk.
        var embeddingsPerSpeaker: [Int: [[Float]]] = [:]
        var filteredSegmentCount = 0
        for segment in speakerSegments {
            if let embedding = segment.embedding, !embedding.isEmpty {
                if segment.qualityScore < 0.3 { filteredSegmentCount += 1; continue }
                if segment.duration < 1.0 { filteredSegmentCount += 1; continue }
                embeddingsPerSpeaker[segment.speakerId, default: []].append(embedding)
            }
        }
        if filteredSegmentCount > 0 {
            AppLogger.transcription.info("Filtered low-quality mic segments", [
                "filtered": "\(filteredSegmentCount)",
                "total": "\(speakerSegments.count)"
            ])
        }

        // Ghost speaker fix: same as system path.
        let allSpeakerIds = Set(speakerSegments.map { $0.speakerId })
        let ghostSpeakerIds = allSpeakerIds.subtracting(embeddingsPerSpeaker.keys)
        var ghostSpeakerIdSet = Set<Int>()
        for ghostId in ghostSpeakerIds {
            let bestSegment = speakerSegments
                .filter { segment in
                    guard segment.speakerId == ghostId, let embedding = segment.embedding else { return false }
                    return !embedding.isEmpty
                }
                .max(by: { $0.qualityScore < $1.qualityScore })
            if let segment = bestSegment, let embedding = segment.embedding {
                embeddingsPerSpeaker[ghostId] = [embedding]
                ghostSpeakerIdSet.insert(ghostId)
            }
        }

        var speakerMatchResults: [Int: (persistentId: UUID, similarity: Double, secondSimilarity: Double, averageSimilarity: Double, secondAverageSimilarity: Double)] = [:]
        var speakerNewProfiles: [Int: UUID] = [:]
        var speakerIdRemap: [Int: Int] = [:]
        var newlyCreatedProfileIds: Set<UUID> = []

        // Pre-compute unweighted means for non-ghost speakers so the ghost merge inner
        // loop doesn't recompute the same means once per ghost (O(G×N) → O(N)).
        let nonGhostMeans: [Int: [Float]] = embeddingsPerSpeaker
            .filter { !ghostSpeakerIdSet.contains($0.key) }
            .reduce(into: [:]) { $0[$1.key] = Self.computeMeanEmbedding($1.value) }

        // Rejected-sample vetoes for matching (empty until a correction records one).
        let negativeExemplarsByProfile = speakerDB.negativeExemplarsByProfile()

        for (speakerId, embeddings) in embeddingsPerSpeaker {
            let meanEmbedding = Self.computeMeanEmbedding(embeddings)
            let isGhost = ghostSpeakerIdSet.contains(speakerId)

            if isGhost {
                let mergeCandidate = Self.bestGhostSpeakerMergeCandidate(
                    for: meanEmbedding,
                    nonGhostMeans: nonGhostMeans
                )
                if let candidate = mergeCandidate, candidate.similarity >= speakerThresholds.ghostMergeFloor {
                    speakerIdRemap[speakerId] = candidate.speakerId
                } else {
                    let newProfile = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding, existingId: nil)
                    speakerNewProfiles[speakerId] = newProfile.id
                    newlyCreatedProfileIds.insert(newProfile.id)
                }
                continue
            }

            let adaptiveThreshold = speakerThresholds.adaptiveMatch(forSegmentCount: embeddings.count)

            // Write-back is DEFERRED until after the cross-cluster decision below (#6/#8 — same
            // rationale as the system path: matching reads only the existingProfiles snapshot, so
            // deferring the blend changes no match decision, and a spun-off distinct voice never
            // contaminates the shared profile).
            if let matchResult = Self.matchAgainstProfiles(meanEmbedding, profiles: existingProfiles, threshold: adaptiveThreshold, negativeExemplarsByProfile: negativeExemplarsByProfile, thresholds: speakerThresholds) {
                speakerMatchResults[speakerId] = (matchResult.profileId, matchResult.similarity, matchResult.secondBestSimilarity, matchResult.averageSimilarity, matchResult.secondBestAverageSimilarity)
            } else {
                let newProfile = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding, existingId: nil)
                speakerNewProfiles[speakerId] = newProfile.id
                newlyCreatedProfileIds.insert(newProfile.id)
            }
        }

        // Cross-cluster link/merge (#8): only fuse same-profile clusters that are directly similar
        // to each other; spin distinct voices off to their own profile (see system path for the
        // full rationale). `nonGhostMeans` holds the matched mean per non-ghost speaker.
        let micLinkPlan = Self.planCrossClusterLinks(
            matchedProfileBySpeaker: speakerMatchResults.mapValues { $0.persistentId },
            matchSimilarityBySpeaker: speakerMatchResults.mapValues { $0.similarity },
            meanBySpeaker: nonGhostMeans,
            segmentCountBySpeaker: embeddingsPerSpeaker.mapValues { $0.count },
            thresholds: speakerThresholds
        )
        for rep in micLinkPlan.spinOffs {
            let repMean = nonGhostMeans[rep]
                ?? Self.computeMeanEmbedding(embeddingsPerSpeaker[rep] ?? [])
            let spinoff = speakerDB.addOrUpdateSpeaker(embedding: repMean, existingId: nil)
            speakerMatchResults.removeValue(forKey: rep)
            speakerNewProfiles[rep] = spinoff.id
            newlyCreatedProfileIds.insert(spinoff.id)
        }
        for (other, rep) in micLinkPlan.remaps {
            speakerIdRemap[other] = rep
            speakerMatchResults.removeValue(forKey: other)
        }
        // Collapse chains before anything reads this map — see the matching
        // comment on the system-audio path above.
        speakerIdRemap = Self.resolvingRemapChains(speakerIdRemap)

        // Deferred write-back (#6): blend each surviving matched cluster under the contamination
        // gate. Spun-off clusters were removed above and never write into the shared profile.
        for (speakerId, match) in speakerMatchResults {
            guard let meanEmbedding = nonGhostMeans[speakerId] else { continue }
            let writeAlpha = SpeakerWritePathPolicy.voiceprintBlendAlpha(
                similarity: match.similarity,
                secondBestSimilarity: match.secondSimilarity,
                thresholds: speakerThresholds
            )
            _ = speakerDB.addOrUpdateSpeaker(
                embedding: meanEmbedding,
                existingId: match.persistentId,
                blendAlpha: writeAlpha
            )
        }

        // Build speaker contexts keyed by effective speakerId (post-remap).
        var speakerContexts: [String: ChannelSpeakerContext] = [:]
        let effectiveSpeakerIds = Set(speakerSegments.map { speakerIdRemap[$0.speakerId] ?? $0.speakerId })
        for effectiveSpeakerId in effectiveSpeakerIds {
            let persistentId = speakerMatchResults[effectiveSpeakerId]?.persistentId
                ?? speakerNewProfiles[effectiveSpeakerId]
            guard let persistentId else { continue }

            let sessionEmbedding: [Float]?
            if let embeddings = embeddingsPerSpeaker[effectiveSpeakerId], !embeddings.isEmpty {
                sessionEmbedding = Self.computeMeanEmbedding(embeddings)
            } else {
                sessionEmbedding = nil
            }
            let matchedProfileSnapshot = speakerMatchResults[effectiveSpeakerId]
                .flatMap { match in existingProfiles.first(where: { $0.id == match.persistentId }) }

            speakerContexts[String(effectiveSpeakerId)] = ChannelSpeakerContext(
                persistentSpeakerId: persistentId,
                sessionEmbedding: sessionEmbedding,
                matchedProfileSnapshot: matchedProfileSnapshot,
                matchSimilarity: speakerMatchResults[effectiveSpeakerId]?.similarity,
                matchSecondSimilarity: speakerMatchResults[effectiveSpeakerId]?.secondSimilarity,
                matchAverageSimilarity: speakerMatchResults[effectiveSpeakerId]?.averageSimilarity,
                matchSecondBestAverageSimilarity: speakerMatchResults[effectiveSpeakerId]?.secondAverageSimilarity
            )
        }

        // All mic STT completed before the speaker-store writes above. Building
        // utterances from those local results is now non-throwing.
        var utterances: [TranscriptionUtterance] = []
        for transcribed in transcribedSegments {
            let segment = transcribed.segment
            let effectiveSpeakerId = speakerIdRemap[segment.speakerId] ?? segment.speakerId
            let persistentId: UUID?
            let similarity: Double?
            if let match = speakerMatchResults[effectiveSpeakerId] {
                persistentId = match.persistentId
                similarity = match.similarity
            } else {
                persistentId = speakerNewProfiles[effectiveSpeakerId]
                similarity = nil
            }

            utterances.append(TranscriptionUtterance(
                start: segment.startTime,
                end: segment.endTime,
                channel: 0,  // mic
                speakerId: effectiveSpeakerId,
                persistentSpeakerId: persistentId,
                matchSimilarity: similarity,
                transcript: transcribed.text
            ))
        }

        return MicChannelResult(
            utterances: utterances,
            speakerContexts: speakerContexts,
            newlyCreatedProfileIds: newlyCreatedProfileIds
        )
    }

    // MARK: - Embedding Quality

    /// Calculate embedding weight based on mic activity fraction during a system audio segment.
    /// Returns nil if the segment should be excluded entirely (>80% mic overlap).
    /// Uses a 4-tier gradient to avoid sharp threshold cliffs:
    ///   - >80%: excluded (mic voice dominates system audio)
    ///   - 50-80%: weight 0.2 (heavily contaminated)
    ///   - 30-50%: weight 0.5 (moderately contaminated)
    ///   - <30%: weight 1.0 (clean)
    nonisolated static func embeddingWeight(forMicFraction micFraction: Double) -> Float? {
        if micFraction > 0.8 { return nil }
        switch micFraction {
        case 0.5...: return 0.2
        case 0.3...: return 0.5
        default: return 1.0
        }
    }
}

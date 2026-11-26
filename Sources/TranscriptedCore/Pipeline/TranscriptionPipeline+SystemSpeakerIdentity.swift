import Foundation

// MARK: - System Channel Speaker Identity

extension Transcription {

    typealias SystemSpeakerMatch = (
        persistentId: UUID,
        similarity: Double,
        secondSimilarity: Double,
        averageSimilarity: Double,
        secondAverageSimilarity: Double
    )

    /// Who each system-audio diarizer speaker is: DB matches, new profiles,
    /// remaps (ghost merges and cross-cluster fusion), and the per-speaker
    /// contexts the transcript saver needs.
    struct SystemSpeakerIdentities {
        let matchResults: [Int: SystemSpeakerMatch]
        let newProfiles: [Int: UUID]
        let idRemap: [Int: Int]
        let speakerContexts: [String: ChannelSpeakerContext]
    }

    /// Pure, read-only match + clustering plan for system-audio diarizer speakers.
    /// Holds everything needed to commit `speakerDB` writes AFTER system STT, mic STT,
    /// and cancellation checks succeed — so a failed or cancelled transcription stage
    /// never mutates the speaker database.
    struct SystemSpeakerIdentityPlan {
        struct StandaloneGhost {
            let speakerId: Int
            let meanEmbedding: [Float]
            let mergeCandidate: GhostSpeakerMergeCandidate?
        }

        struct UnmatchedSpeaker {
            let speakerId: Int
            let meanEmbedding: [Float]
            let adaptiveThreshold: Double
            let segmentCount: Int
        }

        struct SpinOffSpeaker {
            let speakerId: Int
            let meanEmbedding: [Float]
        }

        let embeddingsPerSpeaker: [Int: [[Float]]]
        let embeddingWeights: [Int: [Float]]
        let matchedMeanPerSpeaker: [Int: [Float]]
        let matchResults: [Int: SystemSpeakerMatch]
        let idRemap: [Int: Int]
        let standaloneGhosts: [StandaloneGhost]
        let unmatchedSpeakers: [UnmatchedSpeaker]
        let spinOffSpeakers: [SpinOffSpeaker]
        let effectiveSpeakerIds: Set<Int>
        let speakerThresholds: SpeakerEmbeddingThresholds
    }

    /// Pure read-only planning step: aggregate embeddings per diarizer speaker,
    /// match them against `existingProfiles`, and resolve ghost merges and
    /// cross-cluster links without touching `speakerDB`.
    nonisolated static func planSystemSpeakerIdentities(
        speakerSegments: [SpeakerSegment],
        existingProfiles: [SpeakerProfile],
        negativeExemplarsByProfile: [UUID: [[Float]]],
        speakerThresholds: SpeakerEmbeddingThresholds,
        micActiveFraction: (_ startTime: Double, _ endTime: Double) -> Double
    ) -> SystemSpeakerIdentityPlan {
        // Aggregate embeddings per diarizer speaker ID for stable matching.
        // Instead of matching each segment independently (noisy), we compute
        // a mean embedding per speaker and match that once against the DB.
        // Quality gate: skip low-quality segments to prevent noisy embeddings
        // from polluting the speaker database.
        var embeddingsPerSpeaker: [Int: [[Float]]] = [:]
        var embeddingWeights: [Int: [Float]] = [:]  // 1.0 = clean, 0.3 = mic-contaminated
        var filteredSegmentCount = 0
        var micContaminatedCount = 0
        for segment in speakerSegments {
            if let embedding = segment.embedding, !embedding.isEmpty {
                // Skip segments with very low quality scores — they produce noisy embeddings
                if segment.qualityScore < 0.3 {
                    filteredSegmentCount += 1
                    continue
                }
                // Skip very short segments (< 1.0s) — insufficient audio for reliable voiceprint
                if segment.duration < 1.0 {
                    filteredSegmentCount += 1
                    continue
                }

                // Mic energy gating: when the local user was speaking, system audio
                // embeddings are contaminated with their voice (Zoom echo residual).
                let micFraction = micActiveFraction(segment.startTime, segment.endTime)

                guard let weight = Self.embeddingWeight(forMicFraction: micFraction) else {
                    // >80% overlap with local mic: skip entirely
                    micContaminatedCount += 1
                    continue
                }
                embeddingsPerSpeaker[segment.speakerId, default: []].append(embedding)
                embeddingWeights[segment.speakerId, default: []].append(weight)
            }
        }
        if filteredSegmentCount > 0 {
            AppLogger.transcription.info("Filtered low-quality segments from embedding aggregation", ["filtered": "\(filteredSegmentCount)", "total": "\(speakerSegments.count)"])
        }
        if micContaminatedCount > 0 {
            AppLogger.transcription.info("Mic-contaminated segments excluded from embedding aggregation", [
                "excluded": "\(micContaminatedCount)",
                "total": "\(speakerSegments.count)"
            ])
        }

        // Ghost speaker fix: speakers whose segments were ALL filtered out have no
        // aggregated embedding. Use their best available raw segment embedding as a
        // fallback so every utterance gets a persistent UUID (critical for agent output).
        let allSpeakerIds = Set(speakerSegments.map { $0.speakerId })
        let ghostSpeakerIds = allSpeakerIds.subtracting(embeddingsPerSpeaker.keys)
        var ghostSpeakerIdSet = Set<Int>()
        for ghostId in ghostSpeakerIds.sorted() {
            let bestSegment = speakerSegments
                .filter { segment in
                    guard segment.speakerId == ghostId, let embedding = segment.embedding else { return false }
                    return !embedding.isEmpty
                }
                .max(by: { $0.qualityScore < $1.qualityScore })
            if let segment = bestSegment, let embedding = segment.embedding {
                embeddingsPerSpeaker[ghostId] = [embedding]
                ghostSpeakerIdSet.insert(ghostId)
                AppLogger.transcription.info("Ghost speaker recovered with best-effort embedding", [
                    "speakerId": "\(ghostId)",
                    "qualityScore": String(format: "%.2f", segment.qualityScore)
                ])
            }
        }

        // Match each speaker's mean embedding against the DB snapshot once.
        // All DB writes are deferred to `commitSystemSpeakerIdentities`.
        var speakerMatchResults: [Int: SystemSpeakerMatch] = [:]
        var speakerIdRemap: [Int: Int] = [:]
        var standaloneGhosts: [SystemSpeakerIdentityPlan.StandaloneGhost] = []
        var unmatchedSpeakers: [SystemSpeakerIdentityPlan.UnmatchedSpeaker] = []
        // Session mean embedding actually matched for each non-ghost speaker, kept so the
        // cross-cluster link/merge step can compare clusters directly to each other (#8)
        // instead of relying only on "matched the same profile".
        var matchedMeanPerSpeaker: [Int: [Float]] = [:]

        // Pre-compute unweighted means for non-ghost speakers so the ghost merge inner
        // loop doesn't recompute the same means once per ghost (O(G×N) → O(N)).
        let nonGhostMeans: [Int: [Float]] = embeddingsPerSpeaker
            .filter { !ghostSpeakerIdSet.contains($0.key) }
            .reduce(into: [:]) { $0[$1.key] = Self.computeMeanEmbedding($1.value) }

        for speakerId in embeddingsPerSpeaker.keys.sorted() {
            guard let embeddings = embeddingsPerSpeaker[speakerId] else { continue }
            let weights = embeddingWeights[speakerId] ?? Array(repeating: Float(1.0), count: embeddings.count)
            let meanEmbedding = Self.computeWeightedMeanEmbedding(embeddings, weights: weights)

            let isGhost = ghostSpeakerIdSet.contains(speakerId)
            if !isGhost { matchedMeanPerSpeaker[speakerId] = meanEmbedding }

            // Ghost speakers have unreliable embeddings (laughter, coughs, codec artifacts).
            // Prefer force-merging into the closest real speaker, but if every detected
            // speaker is a ghost we still need a persistent UUID for later transcript
            // metadata updates, so fall back to creating a best-effort profile on commit.
            if isGhost {
                let mergeCandidate = Self.bestGhostSpeakerMergeCandidate(
                    for: meanEmbedding,
                    nonGhostMeans: nonGhostMeans
                )
                if let candidate = mergeCandidate, candidate.similarity >= speakerThresholds.ghostMergeFloor {
                    speakerIdRemap[speakerId] = candidate.speakerId
                    AppLogger.transcription.info("Ghost speaker force-merged", [
                        "ghostSpk": "\(speakerId)",
                        "into": "\(candidate.speakerId)",
                        "similarity": String(format: "%.3f", candidate.similarity),
                        "threshold": String(format: "%.2f", speakerThresholds.ghostMergeFloor)
                    ])
                } else {
                    standaloneGhosts.append(SystemSpeakerIdentityPlan.StandaloneGhost(
                        speakerId: speakerId,
                        meanEmbedding: meanEmbedding,
                        mergeCandidate: mergeCandidate
                    ))
                }
                continue
            }

            // Adaptive threshold: require higher similarity when we have fewer segments.
            // A single 2s segment can false-match at 0.79; 4+ segments give a reliable mean.
            let adaptiveThreshold = speakerThresholds.adaptiveMatch(forSegmentCount: embeddings.count)

            if let matchResult = Self.matchAgainstProfiles(meanEmbedding, profiles: existingProfiles, threshold: adaptiveThreshold, negativeExemplarsByProfile: negativeExemplarsByProfile, thresholds: speakerThresholds) {
                speakerMatchResults[speakerId] = (matchResult.profileId, matchResult.similarity, matchResult.secondBestSimilarity, matchResult.averageSimilarity, matchResult.secondBestAverageSimilarity)
                let matchedProfile = existingProfiles.first(where: { $0.id == matchResult.profileId })
                AppLogger.transcription.info("Speaker matched DB profile", [
                    "speakerId": "\(speakerId)",
                    "similarity": String(format: "%.3f", matchResult.similarity),
                    "secondBest": String(format: "%.3f", matchResult.secondBestSimilarity),
                    "threshold": String(format: "%.2f", adaptiveThreshold),
                    "segmentsAveraged": "\(embeddings.count)",
                    "profileName": matchedProfile?.displayName ?? "unnamed",
                    "profileCallCount": "\(matchedProfile?.callCount ?? 0)"
                ])
            } else {
                unmatchedSpeakers.append(SystemSpeakerIdentityPlan.UnmatchedSpeaker(
                    speakerId: speakerId,
                    meanEmbedding: meanEmbedding,
                    adaptiveThreshold: adaptiveThreshold,
                    segmentCount: embeddings.count
                ))
            }
        }

        // Cross-cluster link/merge (#8): two diarizer clusters that matched the SAME DB profile
        // are candidates for fusion into one transcript row. The 0.70 attach floor that bound
        // each cluster to the profile is too loose to ALSO prove they are the same person — two
        // distinct people who each merely resemble one profile would be silently fused, then
        // named once in review. Decouple it: only fuse clusters that are directly similar to
        // EACH OTHER (cross-cluster cosine ≥ link floor — the genuine over-segmentation
        // signature). A cluster that matched the same profile but is a distinct voice is spun
        // off to its own profile so it stays independently nameable.
        let linkPlan = Self.planCrossClusterLinks(
            matchedProfileBySpeaker: speakerMatchResults.mapValues { $0.persistentId },
            matchSimilarityBySpeaker: speakerMatchResults.mapValues { $0.similarity },
            meanBySpeaker: matchedMeanPerSpeaker,
            segmentCountBySpeaker: embeddingsPerSpeaker.mapValues { $0.count },
            thresholds: speakerThresholds
        )
        // Spin-off representatives: a distinct voice (or fragments of one) that only resembled the
        // matched profile — give it its own identity on commit so review names it separately.
        // Removed from the matched set so it never writes back into the shared profile.
        var spinOffSpeakers: [SystemSpeakerIdentityPlan.SpinOffSpeaker] = []
        for rep in linkPlan.spinOffs {
            let repMean = matchedMeanPerSpeaker[rep]
                ?? Self.computeMeanEmbedding(embeddingsPerSpeaker[rep] ?? [])
            speakerMatchResults.removeValue(forKey: rep)
            spinOffSpeakers.append(SystemSpeakerIdentityPlan.SpinOffSpeaker(
                speakerId: rep,
                meanEmbedding: repMean
            ))
        }
        // Group members fuse into their representative; drop their own match so only the
        // representative writes back (keeper group → shared profile, spin-off group → new profile).
        for (other, rep) in linkPlan.remaps {
            speakerIdRemap[other] = rep
            speakerMatchResults.removeValue(forKey: other)
        }
        // Collapse chains before anything reads this map. The ghost-merge
        // pass above can point G at B while this pass points B at A, and
        // every read site does a single dictionary lookup — so G would
        // resolve to B, which was just removed from both
        // speakerMatchResults and speakerNewProfiles. Those utterances
        // would end up with no persistent id at all, surfacing as an extra
        // unnameable "Speaker N" block in the saved transcript whose lines
        // belong to someone already named in the same file.
        speakerIdRemap = Self.resolvingRemapChains(speakerIdRemap)
        if !linkPlan.remaps.isEmpty {
            AppLogger.transcription.info("Merged speaker IDs with same DB profile", [
                "merged": linkPlan.remaps.keys.map { "spk\($0)" }.joined(separator: "+"),
                "remaps": "\(linkPlan.remaps.count)"
            ])
        }
        if !linkPlan.spinOffs.isEmpty {
            AppLogger.transcription.info("Cross-cluster fusion declined — distinct voices spun off", [
                "spunOff": linkPlan.spinOffs.map { "spk\($0)" }.joined(separator: "+"),
                "linkFloor": String(format: "%.2f", speakerThresholds.crossClusterLink)
            ])
        }

        let effectiveSpeakerIds = Set(
            speakerSegments.map { speakerIdRemap[$0.speakerId] ?? $0.speakerId }
        )

        return SystemSpeakerIdentityPlan(
            embeddingsPerSpeaker: embeddingsPerSpeaker,
            embeddingWeights: embeddingWeights,
            matchedMeanPerSpeaker: matchedMeanPerSpeaker,
            matchResults: speakerMatchResults,
            idRemap: speakerIdRemap,
            standaloneGhosts: standaloneGhosts,
            unmatchedSpeakers: unmatchedSpeakers,
            spinOffSpeakers: spinOffSpeakers,
            effectiveSpeakerIds: effectiveSpeakerIds,
            speakerThresholds: speakerThresholds
        )
    }

    /// Commit a planned system-channel identity resolution to `speakerDB`.
    /// Call ONLY after system STT, mic STT, and cancellation checks have succeeded.
    nonisolated static func commitSystemSpeakerIdentities(
        _ plan: SystemSpeakerIdentityPlan,
        existingProfiles: [SpeakerProfile],
        speakerDB: any SpeakerStore
    ) -> SystemSpeakerIdentities {
        var speakerNewProfiles: [Int: UUID] = [:]

        for ghost in plan.standaloneGhosts {
            let newProfile = speakerDB.addOrUpdateSpeaker(embedding: ghost.meanEmbedding, existingId: nil)
            speakerNewProfiles[ghost.speakerId] = newProfile.id
            var context = [
                "speakerId": "\(ghost.speakerId)",
                "threshold": String(format: "%.2f", plan.speakerThresholds.ghostMergeFloor)
            ]
            if let candidate = ghost.mergeCandidate {
                context["bestNonGhostSpk"] = "\(candidate.speakerId)"
                context["similarity"] = String(format: "%.3f", candidate.similarity)
                context["reason"] = "below-minimum-similarity"
            } else {
                context["reason"] = "no-non-ghost-speaker-to-merge-into"
            }
            AppLogger.transcription.warning("Ghost speaker kept as standalone best-effort profile", context)
        }

        for unmatched in plan.unmatchedSpeakers {
            let newProfile = speakerDB.addOrUpdateSpeaker(embedding: unmatched.meanEmbedding, existingId: nil)
            speakerNewProfiles[unmatched.speakerId] = newProfile.id
            AppLogger.transcription.info("Speaker new profile created", [
                "speakerId": "\(unmatched.speakerId)",
                "threshold": String(format: "%.2f", unmatched.adaptiveThreshold),
                "segmentsAveraged": "\(unmatched.segmentCount)"
            ])
        }

        for spinOff in plan.spinOffSpeakers {
            let spinoff = speakerDB.addOrUpdateSpeaker(embedding: spinOff.meanEmbedding, existingId: nil)
            speakerNewProfiles[spinOff.speakerId] = spinoff.id
        }

        // Deferred write-back (#6): blend each surviving matched cluster's session mean into its
        // profile under the write-time contamination gate. A weak or ambiguous match freezes the
        // voiceprint (alpha 0) — still recorded as an appearance, never silently drifting the
        // stored fingerprint. Spun-off clusters were removed from matchResults above and so never
        // contaminate the shared profile.
        for speakerId in plan.matchResults.keys.sorted() {
            guard let match = plan.matchResults[speakerId],
                  let meanEmbedding = plan.matchedMeanPerSpeaker[speakerId] else { continue }
            let writeAlpha = SpeakerWritePathPolicy.voiceprintBlendAlpha(
                similarity: match.similarity,
                secondBestSimilarity: match.secondSimilarity,
                thresholds: plan.speakerThresholds
            )
            _ = speakerDB.addOrUpdateSpeaker(
                embedding: meanEmbedding,
                existingId: match.persistentId,
                blendAlpha: writeAlpha
            )
            if writeAlpha < SpeakerWritePathPolicy.confidentBlendAlpha {
                AppLogger.transcription.info("Voiceprint write-back gated", [
                    "speakerId": "\(speakerId)",
                    "similarity": String(format: "%.3f", match.similarity),
                    "secondBest": String(format: "%.3f", match.secondSimilarity),
                    "writeBackAlpha": String(format: "%.2f", writeAlpha)
                ])
            }
        }

        var systemSpeakerContexts: [String: ChannelSpeakerContext] = [:]
        for effectiveSpeakerId in plan.effectiveSpeakerIds {
            let persistentId = plan.matchResults[effectiveSpeakerId]?.persistentId
                ?? speakerNewProfiles[effectiveSpeakerId]
            guard let persistentId else { continue }

            let sessionEmbedding: [Float]?
            if let embeddings = plan.embeddingsPerSpeaker[effectiveSpeakerId], !embeddings.isEmpty {
                let weights = plan.embeddingWeights[effectiveSpeakerId]
                    ?? Array(repeating: Float(1.0), count: embeddings.count)
                sessionEmbedding = Self.computeWeightedMeanEmbedding(embeddings, weights: weights)
            } else {
                sessionEmbedding = nil
            }

            let matchedProfileSnapshot = plan.matchResults[effectiveSpeakerId]
                .flatMap { match in
                    existingProfiles.first(where: { $0.id == match.persistentId })
                }

            systemSpeakerContexts[String(effectiveSpeakerId)] = ChannelSpeakerContext(
                persistentSpeakerId: persistentId,
                sessionEmbedding: sessionEmbedding,
                matchedProfileSnapshot: matchedProfileSnapshot,
                matchSimilarity: plan.matchResults[effectiveSpeakerId]?.similarity,
                matchSecondSimilarity: plan.matchResults[effectiveSpeakerId]?.secondSimilarity,
                matchAverageSimilarity: plan.matchResults[effectiveSpeakerId]?.averageSimilarity,
                matchSecondBestAverageSimilarity: plan.matchResults[effectiveSpeakerId]?.secondAverageSimilarity
            )
        }

        return SystemSpeakerIdentities(
            matchResults: plan.matchResults,
            newProfiles: speakerNewProfiles,
            idRemap: plan.idRemap,
            speakerContexts: systemSpeakerContexts
        )
    }

    /// Convenience wrapper that plans and commits system-channel speaker identities in one call.
    nonisolated static func resolveSystemSpeakerIdentities(
        speakerSegments: [SpeakerSegment],
        existingProfiles: [SpeakerProfile],
        negativeExemplarsByProfile: [UUID: [[Float]]],
        speakerThresholds: SpeakerEmbeddingThresholds,
        speakerDB: any SpeakerStore,
        micActiveFraction: (_ startTime: Double, _ endTime: Double) -> Double
    ) -> SystemSpeakerIdentities {
        let plan = planSystemSpeakerIdentities(
            speakerSegments: speakerSegments,
            existingProfiles: existingProfiles,
            negativeExemplarsByProfile: negativeExemplarsByProfile,
            speakerThresholds: speakerThresholds,
            micActiveFraction: micActiveFraction
        )
        return commitSystemSpeakerIdentities(
            plan,
            existingProfiles: existingProfiles,
            speakerDB: speakerDB
        )
    }
}

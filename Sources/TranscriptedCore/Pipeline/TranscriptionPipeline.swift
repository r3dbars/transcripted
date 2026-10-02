import Foundation
@preconcurrency import AVFoundation
import Accelerate
import FluidAudio

// MARK: - Local Multichannel Transcription

extension Transcription {

    /// Transcribe system audio using local Parakeet STT + offline diarization,
    /// with optional mic audio for mixed live meeting captures.
    ///
    /// Pipeline:
    /// 1. Load & resample the captured audio files to 16kHz mono
    /// 2. Run offline diarization (Nemotron or pyannote) on system audio -> speaker segments with embeddings
    /// 3. Transcribe each system-audio speaker segment with Parakeet
    /// 4. When present, transcribe mic audio with Parakeet.
    ///    - If `splitLocalSpeakers` is false (default), splits by silence and tags
    ///      every utterance as the single "You" speaker.
    ///    - If true, runs diarization on the mic channel too and threads
    ///      per-speaker embeddings through the same classification/matching path
    ///      used for system audio. Surfaces multiple local speakers in the naming sheet.
    /// 5. Match speaker embeddings against persistent SpeakerDatabase
    /// 6. Merge available utterances chronologically
    ///
    /// Note: nonisolated to keep heavy compute off the main thread
    nonisolated func transcribeMultichannel(
        micURL: URL?,
        systemURL: URL,
        splitLocalSpeakers: Bool = false,
        languageSelection: TranscriptionLanguageSelection = .automatic,
        speakerSeparation: SpeakerSeparationOptions? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> TranscriptionResult {

        let parakeet = await MainActor.run { self.parakeet }
        let diarization = await MainActor.run { self.diarization }
        let speakerDB = await MainActor.run { self.speakerDB }

        await MainActor.run {
            self.isProcessing = true
            self.error = nil
            self.processingStatus = "Preparing audio..."
        }

        let processingStartTime = Date()

        do {
            let duration = try Self.longestAudioDuration(micURL: micURL, systemURL: systemURL)
            MeetingPipelineTimings.current?.recordRecordingLength(seconds: duration)

            onProgress?(0.0)

            // Step 1: Load and resample both audio files to 16kHz mono
            await MainActor.run {
                self.processingStatus = "Loading audio..."
            }

            AppLogger.transcription.info("Loading and resampling audio to 16kHz")
            let resampleStart = CFAbsoluteTimeGetCurrent()

            // Load sequentially to avoid both resampling buffers in memory simultaneously.
            // async let forces concurrent resampling (~460MB peak for long recordings);
            // sequential means only one resampling buffer exists at a time.
            //
            // Both are whole-meeting 16kHz buffers (~460MB per channel for a
            // 2h recording), declared `var` so each can be cleared (`= []`)
            // right after its last use below instead of staying alive for the
            // entire diarize → transcribe → merge run.
            var systemSamples: [Float]
            var systemAudioLoadError: Error?
            do {
                systemSamples = try AudioResampler.loadAndResample(url: systemURL, targetRate: 16000)
            } catch {
                // Mirror the microphone fallback below: a damaged/empty remote
                // track must not erase a valid local conversation. The
                // too-short check further down routes to the mic-only pipeline
                // when the mic track is usable.
                systemSamples = []
                systemAudioLoadError = error
                AppLogger.transcription.warning("System audio could not be loaded; will fall back to microphone-only if usable", [
                    "fallback": "microphone_only"
                ])
            }
            var micSamples: [Float]
            var microphoneAudioOutcome: TranscriptionResult.MicrophoneAudioOutcome
            if let micURL {
                do {
                    micSamples = try AudioResampler.loadAndResample(url: micURL, targetRate: 16000)
                    microphoneAudioOutcome = micSamples.isEmpty ? .unusable : .usable
                } catch {
                    // A damaged/empty local track must not erase a valid remote
                    // conversation. Keep the artifact for retry, but run the
                    // transcription as system-audio-only partial success.
                    micSamples = []
                    microphoneAudioOutcome = .unusable
                    AppLogger.transcription.warning("Microphone audio could not be loaded; continuing with system audio", [
                        "fallback": "system_audio_only"
                    ])
                }
            } else {
                micSamples = []
                microphoneAudioOutcome = .notProvided
            }

            let resampleTime = CFAbsoluteTimeGetCurrent() - resampleStart
            AppLogger.transcription.info("Resampling completed in \(String(format: "%.2f", resampleTime))s")

            AppLogger.transcription.debug("System: \(systemSamples.count) samples (\(String(format: "%.1f", Double(systemSamples.count) / 16000))s)")
            if let _ = micURL {
                AppLogger.transcription.debug("Mic: \(micSamples.count) samples (\(String(format: "%.1f", Double(micSamples.count) / 16000))s)")
            } else {
                AppLogger.transcription.debug("Mic: skipped for system-audio-only transcription")
            }

            var micSignalAnalysis: AudioSignalAnalysis?
            if micURL != nil, !micSamples.isEmpty {
                let rawMicAnalysis = AudioSignalRecovery.analyze(samples: micSamples, sampleRate: 16000)
                var context = rawMicAnalysis.context
                context["suggested_gain"] = String(format: "%.2f", AudioSignalRecovery.normalizationGain(for: rawMicAnalysis))
                AppLogger.transcription.info("Analyzed meeting mic signal", context)
                if AudioSignalRecovery.hasUsableCaptureSignal(samples: micSamples, sampleRate: 16000) {
                    micSignalAnalysis = rawMicAnalysis
                } else {
                    context["fallback"] = "system_audio_only"
                    AppLogger.transcription.warning("Microphone artifact had no usable capture signal; continuing with system audio", context)
                    micSamples = []
                    micSignalAnalysis = nil
                    microphoneAudioOutcome = .unusable
                }
            } else {
                micSignalAnalysis = nil
            }

            // Validate system audio has meaningful content (at least 1 second at 16kHz).
            // Without this, a failed system audio capture produces an empty transcript.
            let hasUsableSystemAudio = systemSamples.count >= 16000
            let systemAudioOutcome: TranscriptionResult.SystemAudioOutcome = hasUsableSystemAudio
                ? .usable
                : .unusable
            if !hasUsableSystemAudio {
                // The mic side degrades gracefully twice above; this side used
                // to throw even with a full-length mic track sitting next to
                // it — and `startTranscription` admits exactly that
                // combination by design (`hasUsableMicAudio` alone passes its
                // gate). `recordingTooShort` is both non-retryable and
                // non-recoverable, so that turned a good recording into a dead
                // failed-queue row the user could only dismiss. Route to the
                // mic-only pipeline instead, and only fail when neither track
                // has usable audio. `micSamples` is already emptied above when
                // the mic track has no usable capture signal, so this reads
                // real usability rather than mere presence.
                if micURL != nil, micSamples.count >= 16000 {
                    AppLogger.transcription.warning("System audio too short or empty; transcribing microphone only", [
                        "systemSamples": "\(systemSamples.count)",
                        "micSamples": "\(micSamples.count)",
                        "fallback": "microphone_only"
                    ])
                    // Keep processing in this pipeline rather than delegating to
                    // the legacy single-"You" helper. The mic phase below
                    // preserves `splitLocalSpeakers`, including local diarization
                    // and speaker review when the user enabled it.
                    systemSamples = []
                } else {
                    AppLogger.transcription.error("System audio too short or empty", [
                        "samples": "\(systemSamples.count)",
                        "expectedMinimum": "16000"
                    ])
                    // Preserve the real decode/read failure for system-only
                    // recordings and imports. Converting it to a permanent
                    // `recordingTooShort(0)` hides retryable I/O or format errors.
                    if let systemAudioLoadError {
                        throw systemAudioLoadError
                    }
                    throw PipelineError.recordingTooShort(duration: Double(systemSamples.count) / 16000.0)
                }
            }

            let languageContext = try await parakeet.resolveLanguage(
                representativeSamples: languageSelection == .automatic
                    ? Self.representativeLanguageSamples(tracks: [systemSamples, micSamples]) : [],
                selection: languageSelection
            )

            // Pre-compute mic energy per 100ms frame for embedding quality gating.
            // When the local user is speaking, system audio embeddings are contaminated
            // with their voice echo, producing unreliable remote speaker voiceprints.
            let micEnergyFrameDuration = 0.1  // 100ms frames
            let micFrameSize = Int(16000.0 * micEnergyFrameDuration)  // 1600 samples
            let micFrameCount = micSamples.count / micFrameSize
            var micEnergyPerFrame = [Float](repeating: 0, count: micFrameCount)

            micSamples.withUnsafeBufferPointer { ptr in
                // Security: guard against nil baseAddress (empty buffer) before pointer arithmetic
                guard let baseAddr = ptr.baseAddress else { return }
                for i in 0..<micFrameCount {
                    let start = i * micFrameSize
                    var sumSquares: Float = 0
                    vDSP_dotpr(baseAddr + start, 1,
                               baseAddr + start, 1,
                               &sumSquares,
                               vDSP_Length(micFrameSize))
                    micEnergyPerFrame[i] = sqrt(sumSquares / Float(micFrameSize))
                }
            }
            let micActiveThreshold = AudioSignalRecovery.speechDetectionThreshold(
                for: micSignalAnalysis ?? AudioSignalRecovery.analyze(samples: [], sampleRate: 16000)
            )

            /// Returns the fraction of a time range where the local mic was active (0.0-1.0).
            func micActiveFraction(startTime: Double, endTime: Double) -> Double {
                let startFrame = max(0, Int(startTime / micEnergyFrameDuration))
                let endFrame = min(micFrameCount, Int(endTime / micEnergyFrameDuration))
                guard endFrame > startFrame else { return 0 }
                var activeCount = 0
                for i in startFrame..<endFrame where micEnergyPerFrame[i] >= micActiveThreshold { activeCount += 1 }
                return Double(activeCount) / Double(endFrame - startFrame)
            }

            onProgress?(0.10)

            // Step 2: Run offline diarization on system audio -> speaker segments
            await MainActor.run {
                self.processingStatus = "Analyzing speakers..."
            }

            AppLogger.transcription.info("Running offline diarization on system audio")
            // What diarized this meeting, read right before the first diarize
            // call so a Nemotron load failure records pyannote. Stays nil when
            // no diarizer runs.
            var diarizationRun: DiarizationRunDescriptor?
            let rawSegments: [SpeakerSegment]
            if hasUsableSystemAudio {
                diarizationRun = await Self.diarizationRunDescriptor(of: diarization)
                do {
                    rawSegments = try await Self.diarizeSystemAudio(
                        samples: systemSamples,
                        diarization: diarization,
                        hasMicTrack: micURL != nil && !micSamples.isEmpty,
                        clusteringThreshold: speakerSeparation?.clusteringThreshold
                    )
                } catch let error where Self.isExplicitNoSpeechError(error) {
                    // No mic track to carry the meeting. The diarizer's own
                    // speech detector can miss quiet or distant voices, so do
                    // not give up here: continue with no system segments and
                    // let the last-chance pass at the end look again. It
                    // throws the same `noSpeechDetected` when it finds nothing.
                    AppLogger.transcription.info("Diarizer found no speech in system audio; deferring to the last-chance pass")
                    rawSegments = []
                }
            } else {
                rawSegments = []
            }

            // Post-process diarization segments, but skip the broad pairwise merge
            // phase for PyAnnote/VBx output. Small-cluster absorption, same-voice
            // consolidation (collapses one over-segmented voice so the user names
            // each person once), and DB-informed split still run.
            let existingProfiles = speakerDB.allSpeakers()
            // Rejected-sample vetoes for matching (empty until a correction records one).
            let negativeExemplarsByProfile = speakerDB.negativeExemplarsByProfile()
            let speakerThresholds = diarization.activeSpeakerThresholds
            // Split generously, then merge smartly (SpeakerSeparation.swift): only when
            // the app turned it on for this meeting.
            let separatedSegments = speakerSeparation.map { SpeakerSeparation.apply(rawSegments, options: $0) } ?? rawSegments
            if speakerSeparation != nil {
                AppLogger.transcription.info("Applied speaker separation", [
                    "diarizer": "\(Set(rawSegments.map { $0.speakerId }).count)",
                    "after": "\(Set(separatedSegments.map { $0.speakerId }).count)",
                    "cap": speakerSeparation?.maxSpeakers.map { "\($0)" } ?? "none"
                ])
            }
            let speakerSegments = EmbeddingClusterer.postProcess(
                segments: separatedSegments,
                existingProfiles: existingProfiles,
                pairwiseMergeThreshold: nil,
                consolidationThreshold: speakerThresholds.consolidation,
                thresholds: speakerThresholds
            )

            let rawSpeakerCount = Set(rawSegments.map { $0.speakerId }).count
            let postProcessedSpeakerCount = Set(speakerSegments.map { $0.speakerId }).count
            AppLogger.transcription.info("Post-processed speaker segments", [
                "diarizer": "\(rawSpeakerCount)",
                "after": "\(postProcessedSpeakerCount)",
                "segments": "\(speakerSegments.count)"
            ])

            onProgress?(0.30)

            // Step 3: Transcribe each speaker segment with Parakeet
            await MainActor.run {
                self.processingStatus = "Transcribing system audio..."
            }

            var systemUtterances: [TranscriptionUtterance] = []
            var droppedSegments = 0
            let totalSegments = speakerSegments.count

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
                    let micFraction = micActiveFraction(startTime: segment.startTime, endTime: segment.endTime)

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
                    AppLogger.transcription.info("Ghost speaker recovered with best-effort embedding", [
                        "speakerId": "\(ghostId)",
                        "qualityScore": String(format: "%.2f", segment.qualityScore)
                    ])
                }
            }

            // Match each speaker's mean embedding against the DB once
            // (existingProfiles was already snapshotted above for post-processing)
            var speakerMatchResults: [Int: (persistentId: UUID, similarity: Double, secondSimilarity: Double, averageSimilarity: Double, secondAverageSimilarity: Double)] = [:]
            var speakerNewProfiles: [Int: UUID] = [:]
            var speakerIdRemap: [Int: Int] = [:]
            // Session mean embedding actually matched for each non-ghost speaker, kept so the
            // cross-cluster link/merge step can compare clusters directly to each other (#8)
            // instead of relying only on "matched the same profile".
            var matchedMeanPerSpeaker: [Int: [Float]] = [:]

            // Pre-compute unweighted means for non-ghost speakers so the ghost merge inner
            // loop doesn't recompute the same means once per ghost (O(G×N) → O(N)).
            let nonGhostMeans: [Int: [Float]] = embeddingsPerSpeaker
                .filter { !ghostSpeakerIdSet.contains($0.key) }
                .reduce(into: [:]) { $0[$1.key] = Self.computeMeanEmbedding($1.value) }

            for (speakerId, embeddings) in embeddingsPerSpeaker {
                let weights = embeddingWeights[speakerId] ?? Array(repeating: Float(1.0), count: embeddings.count)
                let meanEmbedding = Self.computeWeightedMeanEmbedding(embeddings, weights: weights)

                let isGhost = ghostSpeakerIdSet.contains(speakerId)
                if !isGhost { matchedMeanPerSpeaker[speakerId] = meanEmbedding }

                // Ghost speakers have unreliable embeddings (laughter, coughs, codec artifacts).
                // Prefer force-merging into the closest real speaker, but if every detected
                // speaker is a ghost we still need a persistent UUID for later transcript
                // metadata updates, so fall back to creating a best-effort profile.
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
                        let newProfile = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding, existingId: nil)
                        speakerNewProfiles[speakerId] = newProfile.id
                        var context = [
                            "speakerId": "\(speakerId)",
                            "threshold": String(format: "%.2f", speakerThresholds.ghostMergeFloor)
                        ]
                        if let candidate = mergeCandidate {
                            context["bestNonGhostSpk"] = "\(candidate.speakerId)"
                            context["similarity"] = String(format: "%.3f", candidate.similarity)
                            context["reason"] = "below-minimum-similarity"
                        } else {
                            context["reason"] = "no-non-ghost-speaker-to-merge-into"
                        }
                        AppLogger.transcription.warning("Ghost speaker kept as standalone best-effort profile", context)
                    }
                    continue
                }

                // Adaptive threshold: require higher similarity when we have fewer segments.
                // A single 2s segment can false-match at 0.79; 4+ segments give a reliable mean.
                let adaptiveThreshold = speakerThresholds.adaptiveMatch(forSegmentCount: embeddings.count)

                // Match only against profiles that existed BEFORE this recording.
                // Write-back is DEFERRED until after the cross-cluster link/merge decision below,
                // so a cluster that turns out to be a distinct voice (spun off) never blends into
                // the shared profile. Matching reads only the `existingProfiles` snapshot, so
                // deferring the blend cannot change any match decision.
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
                    let newProfile = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding, existingId: nil)
                    speakerNewProfiles[speakerId] = newProfile.id
                    AppLogger.transcription.info("Speaker new profile created", [
                        "speakerId": "\(speakerId)",
                        "threshold": String(format: "%.2f", adaptiveThreshold),
                        "segmentsAveraged": "\(embeddings.count)"
                    ])
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
            // matched profile — give it its own identity so review names it separately. Removed from
            // the matched set so it never writes back into the shared profile.
            for rep in linkPlan.spinOffs {
                let repMean = matchedMeanPerSpeaker[rep]
                    ?? Self.computeMeanEmbedding(embeddingsPerSpeaker[rep] ?? [])
                let spinoff = speakerDB.addOrUpdateSpeaker(embedding: repMean, existingId: nil)
                speakerMatchResults.removeValue(forKey: rep)
                speakerNewProfiles[rep] = spinoff.id
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

            // Deferred write-back (#6): now that fusion/spin-off is resolved, blend each surviving
            // matched cluster's session mean into its profile under the write-time contamination
            // gate. A weak or ambiguous match freezes the voiceprint (alpha 0) — still recorded as
            // an appearance, never silently drifting the stored fingerprint. Spun-off clusters were
            // removed from speakerMatchResults above and so never contaminate the shared profile.
            for (speakerId, match) in speakerMatchResults {
                guard let meanEmbedding = matchedMeanPerSpeaker[speakerId] else { continue }
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
            let effectiveSpeakerIds = Set(
                speakerSegments.map { speakerIdRemap[$0.speakerId] ?? $0.speakerId }
            )

            for effectiveSpeakerId in effectiveSpeakerIds {
                let persistentId = speakerMatchResults[effectiveSpeakerId]?.persistentId
                    ?? speakerNewProfiles[effectiveSpeakerId]
                guard let persistentId else { continue }

                let sessionEmbedding: [Float]?
                if let embeddings = embeddingsPerSpeaker[effectiveSpeakerId], !embeddings.isEmpty {
                    let weights = embeddingWeights[effectiveSpeakerId]
                        ?? Array(repeating: Float(1.0), count: embeddings.count)
                    sessionEmbedding = Self.computeWeightedMeanEmbedding(embeddings, weights: weights)
                } else {
                    sessionEmbedding = nil
                }

                let matchedProfileSnapshot = speakerMatchResults[effectiveSpeakerId]
                    .flatMap { match in
                        existingProfiles.first(where: { $0.id == match.persistentId })
                    }

                systemSpeakerContexts[String(effectiveSpeakerId)] = ChannelSpeakerContext(
                    persistentSpeakerId: persistentId,
                    sessionEmbedding: sessionEmbedding,
                    matchedProfileSnapshot: matchedProfileSnapshot,
                    matchSimilarity: speakerMatchResults[effectiveSpeakerId]?.similarity,
                    matchSecondSimilarity: speakerMatchResults[effectiveSpeakerId]?.secondSimilarity,
                    matchAverageSimilarity: speakerMatchResults[effectiveSpeakerId]?.averageSimilarity,
                    matchSecondBestAverageSimilarity: speakerMatchResults[effectiveSpeakerId]?.secondAverageSimilarity
                )
            }

            func appendSystemUtterance(segment: SpeakerSegment, text: String) {
                // Skip empty transcriptions
                guard !text.isEmpty else { return }

                // Apply remap (unifies speakers that matched the same DB profile)
                let effectiveSpeakerId = speakerIdRemap[segment.speakerId] ?? segment.speakerId

                // Use the pre-computed per-speaker match result
                let persistentId: UUID?
                let similarity: Double?
                if let match = speakerMatchResults[effectiveSpeakerId] {
                    persistentId = match.persistentId
                    similarity = match.similarity
                } else {
                    persistentId = speakerNewProfiles[effectiveSpeakerId]
                    similarity = nil
                }

                systemUtterances.append(TranscriptionUtterance(
                    start: segment.startTime,
                    end: segment.endTime,
                    channel: 1,
                    speakerId: effectiveSpeakerId,
                    persistentSpeakerId: persistentId,
                    matchSimilarity: similarity,
                    transcript: text
                ))
            }

            // Short segments are packed into one full speech-to-text window
            // when the engine supports it (see SpeechSegmentPacking); the
            // utterances come out in the same order either way.
            var systemBatcher = SpeechSegmentBatcher<SpeakerSegment>(
                windowSamples: await parakeet.packedSegmentWindowSamples ?? 0
            )
            for (index, segment) in speakerSegments.enumerated() {
                // Allow cancellation between segments (user hit stop or app is terminating)
                try Task.checkCancellation()

                // Extract audio slice for this segment
                let segmentSamples = AudioResampler.extractSlice(
                    from: systemSamples,
                    sampleRate: 16000,
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )

                // Skip segments shorter than 1s — Parakeet requires at least 16,000 samples.
                // A meeting made only of short answers is picked up by the
                // last-chance pass below, which pads them.
                guard segmentSamples.count >= 16000 else { droppedSegments += 1; continue }

                for batch in systemBatcher.add(segment, samples: segmentSamples) {
                    let texts = try await Self.transcribeSegmentBatch(
                        batch.map(\.samples),
                        engine: parakeet,
                        source: .system,
                        language: languageContext
                    )
                    for (entry, text) in zip(batch, texts) {
                        appendSystemUtterance(segment: entry.item, text: text)
                    }
                }

                // Update progress (30% to 65% during system transcription)
                let segmentProgress = 0.30 + (Double(index + 1) / Double(max(1, totalSegments))) * 0.35
                onProgress?(segmentProgress)
            }
            for batch in systemBatcher.finish() {
                let texts = try await Self.transcribeSegmentBatch(
                    batch.map(\.samples),
                    engine: parakeet,
                    source: .system,
                    language: languageContext
                )
                for (entry, text) in zip(batch, texts) {
                    appendSystemUtterance(segment: entry.item, text: text)
                }
            }

            // Segment slicing above was the last use of the whole-meeting
            // system buffer — release it before the mic phase so both
            // channels are never held through the rest of the pipeline.
            systemSamples = []

            AppLogger.transcription.info("System audio transcribed", ["utterances": "\(systemUtterances.count)", "speakers": "\(Set(systemUtterances.map { $0.speakerId }).count)"])

            var micUtterances: [TranscriptionUtterance] = []
            var micSpeakerContexts: [String: ChannelSpeakerContext] = [:]
            var newlyCreatedMicProfileIds: Set<UUID> = []
            var micDiarizerFoundNoSpeech = false

            if microphoneAudioOutcome == .usable, micURL != nil {
                do {
                    // Step 4: Transcribe mic audio.
                    // Two modes:
                    //   A) splitLocalSpeakers == false (default): silence-split, tag as single "You"
                    //   B) splitLocalSpeakers == true: diarize mic, run same classification path
                    //      used for system audio, emit per-speaker utterances
                    await MainActor.run {
                        self.processingStatus = "Transcribing mic audio..."
                    }

                    if splitLocalSpeakers {
                        // B) Mic diarization path
                        let diarizationMicSamples = AudioSignalRecovery.normalizeForSpeech(
                            samples: micSamples,
                            sampleRate: 16000,
                            analysis: micSignalAnalysis
                        ).samples
                        // Normalization above was the last use of the raw mic
                        // buffer in this mode — release it so only the normalized
                        // copy stays alive during mic diarization + transcription.
                        // (`diarizationMicSamples` itself dies at the end of this
                        // branch scope.)
                        micSamples = []
                        if diarizationRun == nil {
                            diarizationRun = await Self.diarizationRunDescriptor(of: diarization)
                        }
                        let micResult = try await Self.processMicChannelWithDiarization(
                            samples: diarizationMicSamples,
                            diarization: diarization,
                            parakeet: parakeet,
                            speakerDB: speakerDB,
                            existingProfiles: existingProfiles,
                            droppedSegments: &droppedSegments,
                            language: languageContext,
                            onProgress: onProgress
                        )
                        micUtterances = micResult.utterances
                        micSpeakerContexts = micResult.speakerContexts
                        newlyCreatedMicProfileIds = micResult.newlyCreatedProfileIds
                        AppLogger.transcription.info("Mic audio diarized + transcribed", [
                            "utterances": "\(micUtterances.count)",
                            "speakers": "\(Set(micUtterances.map { $0.speakerId }).count)",
                            "newProfiles": "\(newlyCreatedMicProfileIds.count)"
                        ])
                    } else {
                        // A) Default: silence-split, single speaker
                        let micSegments = Self.detectSpeechSegments(samples: micSamples, sampleRate: 16000)
                        AppLogger.transcription.info("Mic audio segmented by silence", ["segments": "\(micSegments.count)"])

                        struct PendingMicSegment {
                            let index: Int
                            let start: Double
                            let end: Double
                            let prepared: PreparedMicSegment
                        }
                        func appendMicUtterance(_ pending: PendingMicSegment, text: String) {
                            guard !text.isEmpty else {
                                var context = pending.prepared.analysis.context
                                context["segment_index"] = "\(pending.index)"
                                context["gain"] = String(format: "%.2f", pending.prepared.gain)
                                context["padded_samples"] = "\(pending.prepared.paddedSampleCount)"
                                AppLogger.transcription.warning("Mic segment returned empty transcription", context)
                                return
                            }

                            micUtterances.append(TranscriptionUtterance(
                                start: pending.start,
                                end: pending.end,
                                channel: 0,
                                speakerId: 0,
                                persistentSpeakerId: nil,
                                matchSimilarity: nil,
                                transcript: text
                            ))
                        }

                        var micBatcher = SpeechSegmentBatcher<PendingMicSegment>(
                            windowSamples: await parakeet.packedSegmentWindowSamples ?? 0
                        )
                        for (index, segment) in micSegments.enumerated() {
                            try Task.checkCancellation()

                            let segmentSamples = AudioResampler.extractSlice(
                                from: micSamples,
                                sampleRate: 16000,
                                startTime: segment.start,
                                endTime: segment.end
                            )

                            guard let preparedSegment = Self.prepareMicSegmentForTranscription(
                                samples: segmentSamples,
                                sampleRate: 16000
                            ) else {
                                droppedSegments += 1
                                continue
                            }

                            let pending = PendingMicSegment(
                                index: index,
                                start: segment.start,
                                end: segment.end,
                                prepared: preparedSegment
                            )
                            for batch in micBatcher.add(pending, samples: preparedSegment.samples) {
                                let texts = try await Self.transcribeSegmentBatch(
                                    batch.map(\.samples),
                                    engine: parakeet,
                                    source: .microphone,
                                    language: languageContext
                                )
                                for (entry, text) in zip(batch, texts) {
                                    appendMicUtterance(entry.item, text: text)
                                }
                            }

                            // Update progress (65% to 90% during mic transcription)
                            let micProgress = 0.65 + (Double(index + 1) / Double(max(1, micSegments.count))) * 0.25
                            onProgress?(micProgress)
                        }
                        for batch in micBatcher.finish() {
                            let texts = try await Self.transcribeSegmentBatch(
                                batch.map(\.samples),
                                engine: parakeet,
                                source: .microphone,
                                language: languageContext
                            )
                            for (entry, text) in zip(batch, texts) {
                                appendMicUtterance(entry.item, text: text)
                            }
                        }

                        // Segment slicing above was the last use of the
                        // whole-meeting mic buffer — release it before the
                        // merge/save phase.
                        micSamples = []

                        AppLogger.transcription.info("Mic audio transcribed", ["utterances": "\(micUtterances.count)"])
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Mic-only failures must not erase a completed system-audio
                    // transcript. Cancellation still wins; every other mic
                    // decode/diarization/STT failure becomes an honest partial
                    // result and keeps the original artifact for retry.
                    try Task.checkCancellation()
                    if Self.isExplicitNoSpeechError(error) {
                        // The mic diarizer's speech detector found nothing.
                        // That is an empty mic channel, not a broken one, and
                        // it used to end the whole meeting as "No speech
                        // found" even with a loud mic. Keep the outcome
                        // usable so the last-chance pass below can still
                        // silence-split the mic track. The diarizer throws
                        // before any speaker profile is written.
                        micSamples = []
                        micUtterances = []
                        micSpeakerContexts = [:]
                        newlyCreatedMicProfileIds = []
                        micDiarizerFoundNoSpeech = true
                        AppLogger.transcription.info("Mic diarizer found no speech; deferring to the last-chance pass")
                    } else {
                        guard !systemUtterances.isEmpty else {
                            throw error
                        }
                        micSamples = []
                        micUtterances = []
                        micSpeakerContexts = [:]
                        newlyCreatedMicProfileIds = []
                        microphoneAudioOutcome = .unusable
                        AppLogger.transcription.warning("Microphone processing failed; continuing with system audio", [
                            "fallback": "system_audio_only",
                            "errorType": "\(type(of: error))"
                        ])
                    }
                }
            } else {
                AppLogger.transcription.info("Mic audio skipped", ["reason": "system_audio_only"])
            }

            onProgress?(0.95)

            let processingTime = Date().timeIntervalSince(processingStartTime)

            // Last-chance pass over the tracks whose words depended on the
            // diarizer's speech detector, which can miss quiet or distant
            // voices:
            // - the call side, only when the whole meeting came out empty
            //   (otherwise a quiet remote track is not worth a second STT run);
            // - the split-mode mic whenever it produced no words, even if the
            //   call side did, so voices in the room are not dropped silently.
            // The default mic path already silence-split the whole mic track,
            // so repeating it would only reproduce the same empty result.
            let sweepsSystem = systemUtterances.isEmpty && micUtterances.isEmpty && hasUsableSystemAudio
            let sweepsMic = splitLocalSpeakers && microphoneAudioOutcome == .usable && micUtterances.isEmpty
            if sweepsSystem || sweepsMic {
                await MainActor.run {
                    self.processingStatus = "Checking again for quiet speech..."
                }
                var sweepTracks: [LastChanceSweepTrack] = []
                if sweepsSystem {
                    sweepTracks.append(LastChanceSweepTrack(url: systemURL, channel: .system))
                }
                if sweepsMic, let micURL {
                    sweepTracks.append(LastChanceSweepTrack(url: micURL, channel: .microphone))
                }
                let sweep = try await Self.lastChanceSpeechSweep(
                    tracks: sweepTracks,
                    parakeet: parakeet,
                    language: languageContext,
                    droppedSegments: &droppedSegments
                )
                // Any speaker the diarizer did find said nothing STT could
                // read, so its identity must not be pinned on the recovered
                // words. Recovered words stay unnamed ("Speaker 1" / "You").
                if !sweep.systemUtterances.isEmpty {
                    systemUtterances = sweep.systemUtterances
                    systemSpeakerContexts = [:]
                }
                if !sweep.micUtterances.isEmpty {
                    micUtterances = sweep.micUtterances
                    micSpeakerContexts = [:]
                    newlyCreatedMicProfileIds = []
                } else if micDiarizerFoundNoSpeech, !systemUtterances.isEmpty {
                    // Nothing recoverable in the room either. Say so in the
                    // saved transcript's health, as before this pass existed,
                    // instead of listing a healthy mic with no lines.
                    microphoneAudioOutcome = .unusable
                }
            }

            // Merge consecutive utterances from the same speaker when the gap is small.
            // Diarizer segments often break mid-sentence, producing fragments like:
            //   [00:03] "Opus four point six and"
            //   [00:10] "Sonnet four point six just went live"
            // Merging produces cleaner, more readable transcripts.
            let mergedSystemUtterances = Self.mergeConsecutiveUtterances(systemUtterances, maxGap: 1.5)
            let mergedMicUtterances = Self.mergeConsecutiveUtterances(micUtterances, maxGap: 1.5)
            guard !mergedSystemUtterances.isEmpty || !mergedMicUtterances.isEmpty else {
                AppLogger.transcription.warning("No speech detected after local transcription", [
                    "droppedSegments": "\(droppedSegments)"
                ])
                throw PipelineError.noSpeechDetected
            }

            await MainActor.run {
                self.processingStatus = "Transcription complete!"
                self.isProcessing = false
            }

            onProgress?(1.0)

            AppLogger.transcription.info("Local transcription complete", [
                "micUtterances": "\(mergedMicUtterances.count)",
                "systemUtterances": "\(mergedSystemUtterances.count)",
                "systemSpeakers": "\(Set(mergedSystemUtterances.map { $0.speakerId }).count)",
                "processingTime": "\(String(format: "%.1f", processingTime))s",
                "mergedSystem": "\(systemUtterances.count) → \(mergedSystemUtterances.count)",
                "mergedMic": "\(micUtterances.count) → \(mergedMicUtterances.count)"
            ])

            return TranscriptionResult(
                micUtterances: mergedMicUtterances,
                systemUtterances: mergedSystemUtterances,
                systemSpeakerContexts: systemSpeakerContexts,
                micSpeakerContexts: micSpeakerContexts,
                newlyCreatedMicProfileIds: newlyCreatedMicProfileIds,
                duration: duration,
                processingTime: processingTime,
                droppedSegments: droppedSegments,
                microphoneAudioOutcome: microphoneAudioOutcome,
                systemAudioOutcome: systemAudioOutcome,
                languageContext: languageContext,
                diarization: diarizationRun
            )

        } catch {
            await MainActor.run {
                self.error = "Transcription failed: \(error.localizedDescription)"
                self.isProcessing = false
                self.processingStatus = ""
            }
            throw error
        }
    }
}

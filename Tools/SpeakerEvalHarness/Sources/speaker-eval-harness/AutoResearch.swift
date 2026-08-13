import Foundation
import CryptoKit
import TranscriptedCore

// MARK: - Command

func runAutoResearch(_ args: [String]) {
    guard let manifest = argValue("--manifest", in: args),
          let inputRoot = argValue("--input-root", in: args),
          let out = argValue("--out", in: args) else {
        die("autoeval requires --manifest <sha256.txt> --input-root <dir> --out <report.json> [--configs <configs.json>] [--split train|dev|holdout|all] [--include-events]")
    }
    let splitRaw = argValue("--split", in: args) ?? ResearchSplit.all.rawValue
    guard let split = ResearchSplit(rawValue: splitRaw) else {
        die("unknown split \(splitRaw); expected train|dev|holdout|all")
    }
    let includeEvents = args.contains("--include-events")
    let configs = loadConfigs(path: argValue("--configs", in: args))
    if includeEvents && configs.count != 1 {
        die("--include-events requires exactly one config")
    }
    let inputPaths = loadManifest(manifest, inputRoot: inputRoot)
    guard !inputPaths.isEmpty else { die("manifest contains no fingerprint inputs") }

    var accumulated = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, AccumulatedConfig()) })
    let decoder = JSONDecoder()
    for path in inputPaths {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch { die("cannot read fingerprint cache \(path): \(error.localizedDescription)") }
        let cache: FingerprintCache
        do { cache = try decoder.decode(FingerprintCache.self, from: data) }
        catch { die("bad fingerprint cache \(path): \(error.localizedDescription)") }

        for config in configs {
            let result = evaluate(cache: cache, config: config, split: split, includeEvents: includeEvents)
            accumulated[config.id]!.metrics.merge(result.metrics)
            accumulated[config.id]!.slices[cache.corpus, default: MutableMetrics()].merge(result.metrics)
            for condition in ResearchConditionSlice.allCases {
                let conditionResult = evaluate(
                    cache: cache,
                    config: config,
                    split: split,
                    includeEvents: false,
                    condition: condition
                )
                accumulated[config.id]!.slices[
                    condition.rawValue,
                    default: MutableMetrics()
                ].merge(conditionResult.metrics)
            }
            if includeEvents { accumulated[config.id]!.events.append(contentsOf: result.events) }
        }
        FileHandle.standardError.write(Data("[autoeval] loaded \(cache.corpus) (\(cache.meetings.count) meetings)\n".utf8))
    }

    let reports = configs.map { config -> ConfigReport in
        let result = accumulated[config.id]!
        return ConfigReport(
            config: config,
            metrics: result.metrics.snapshot(),
            slices: result.slices.mapValues { $0.snapshot() },
            events: includeEvents ? result.events : nil
        )
    }
    let report = AutoResearchReport(
        schemaVersion: 3,
        generatedAt: ISO8601DateFormatter().string(from: Date()),
        split: split,
        manifestPath: URL(fileURLWithPath: manifest).standardizedFileURL.path,
        inputRoot: URL(fileURLWithPath: inputRoot).standardizedFileURL.path,
        scoringPurityFloor: ResearchConstants.scoringPurityFloor,
        splitContract: "FNV-1a(family|truth): buckets 0-5 train, 6-7 dev, 8-9 holdout; every quality variant of one identity stays in the same split",
        reports: reports
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let url = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: url, options: .atomic)
    } catch {
        die("failed to write autoeval report \(out): \(error.localizedDescription)")
    }
    for item in reports {
        let m = item.metrics
        let prompt = m.promptsPerRecurringSpeaker.map { String(format: "%.3f", $0) } ?? "n/a"
        let coverage = m.autoCoverage.map { String(format: "%.3f", $0) } ?? "n/a"
        print("AUTOEVAL \(item.config.id) split=\(split.rawValue) repeatPrompts=\(m.repeatPrompts) promptsPerRecurring=\(prompt) autos=\(m.automaticNames) falseAutos=\(m.falseAutomaticNames) falseAutosAllPurities=\(m.falseAutomaticNamesAllPurities) autoCoverage=\(coverage) corrections=\(m.wrongSuggestions) openSetFalseAutos=\(m.openSetFalseAutomaticNames) fragmentation=\(m.fragmentationExcess) falseMerges=\(m.falseMergeIndicators) withinMeetingFalseMerges=\(m.withinMeetingFalseMergeIndicators) crossMeetingFalseMerges=\(m.crossMeetingFalseMergeIndicators)")
    }
}

private func loadConfigs(path: String?) -> [AutoResearchConfig] {
    guard let path else { return [.productionBaseline] }
    let data: Data
    do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
    catch { die("cannot read configs \(path): \(error.localizedDescription)") }
    let decoder = JSONDecoder()
    if let direct = try? decoder.decode([AutoResearchConfig].self, from: data) {
        guard !direct.isEmpty else { die("configs file is empty") }
        ensureUniqueConfigIds(direct)
        return direct
    }
    do {
        let wrapped = try decoder.decode(ConfigEnvelope.self, from: data).configs
        guard !wrapped.isEmpty else { die("configs file is empty") }
        ensureUniqueConfigIds(wrapped)
        return wrapped
    } catch {
        die("bad configs \(path): \(error.localizedDescription)")
    }
}

private func ensureUniqueConfigIds(_ configs: [AutoResearchConfig]) {
    guard Set(configs.map(\.id)).count == configs.count else { die("config ids must be unique") }
}

private func loadManifest(_ path: String, inputRoot: String) -> [String] {
    let contents: String
    do { contents = try String(contentsOfFile: path, encoding: .utf8) }
    catch { die("cannot read manifest \(path): \(error.localizedDescription)") }
    let rootURL = URL(fileURLWithPath: inputRoot, isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    var seen: Set<String> = []
    var inputs: [String] = []

    for (offset, rawLine) in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard fields.count == 2 else {
            die("bad manifest line \(offset + 1): expected SHA256 and relative path")
        }
        let expected = String(fields[0]).lowercased()
        guard expected.count == 64,
              expected.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            die("bad manifest SHA256 on line \(offset + 1)")
        }
        let relative = String(fields[1]).trimmingCharacters(in: .whitespaces)
        guard !(relative as NSString).isAbsolutePath else {
            die("manifest path must be relative on line \(offset + 1): \(relative)")
        }
        let inputURL = rootURL
            .appendingPathComponent(relative)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard inputURL.path.hasPrefix(rootPrefix) else {
            die("manifest path escapes input root on line \(offset + 1): \(relative)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            die("manifest input missing: \(inputURL.path)")
        }
        guard seen.insert(inputURL.path).inserted else {
            die("duplicate manifest input on line \(offset + 1): \(relative)")
        }
        let actual: String
        do { actual = try sha256Hex(of: inputURL) }
        catch { die("cannot hash manifest input \(inputURL.path): \(error.localizedDescription)") }
        guard actual == expected else {
            die("manifest checksum mismatch: \(inputURL.path)")
        }
        inputs.append(inputURL.path)
    }
    return inputs
}

func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: - Chronological replay

enum ResearchConstants {
    static let scoringPurityFloor = 0.80
}

func evaluate(
    cache: FingerprintCache,
    config: AutoResearchConfig,
    split: ResearchSplit,
    includeEvents: Bool,
    condition: ResearchConditionSlice? = nil
) -> CacheEvaluation {
    let family = corpusFamily(cache.corpus)
    let orderedMeetings = cache.meetings.sorted {
        ($0.order, $0.meeting) < ($1.order, $1.meeting)
    }
    let targetTruths = Set(orderedMeetings.flatMap(\.speakers).compactMap { speaker in
        split == .all || identitySplit(family: family, truth: speaker.gtSpeaker) == split
            ? speaker.gtSpeaker
            : nil
    })
    let appearances = Dictionary(
        grouping: orderedMeetings.flatMap(\.speakers).filter {
            targetTruths.contains($0.gtSpeaker) && (condition?.contains($0) ?? true)
        },
        by: \.gtSpeaker
    ).mapValues(\.count)

    var metrics = MutableMetrics()
    metrics.recurringSpeakerUnits = appearances.values.filter { $0 >= 2 }.count
    var profiles: [UUID: SimulatedProfile] = [:]
    var profileForTruth: [String: UUID] = [:]
    var seenTruths: Set<String> = []
    var appearanceNumber: [String: Int] = [:]
    var identitiesWithFirstAuto: Set<String> = []
    var predictedProfilesByTruth: [String: Set<UUID>] = [:]
    var predictedMeetingsByProfileAndTruth: [UUID: [String: Set<String>]] = [:]
    var scoredMeetingsByProfileAndTruth: [UUID: [String: Set<String>]] = [:]
    var scoredMutationProfileIds: Set<UUID> = []
    var events: [TraceEvent] = []
    var nextProfileNumber: UInt64 = 1

    for meeting in orderedMeetings where !meeting.speakers.isEmpty {
        let meetingKey = "\(cache.corpus):\(meeting.meeting)"
        let seenTruthsAtMeetingStart = seenTruths
        let preMeetingProfiles = profiles
        let snapshotIds = profiles.keys.sorted { $0.uuidString < $1.uuidString }
        let snapshotProfiles = snapshotIds.compactMap { id -> SpeakerProfile? in
            guard var profile = profiles[id]?.value, let state = profiles[id] else { return nil }
            profile.callCount = max(1, config.matchMaturityEvidence == .appearances
                ? state.appearanceCount : state.confirmedMeetings.count)
            profile.confirmedMeetingCount = state.confirmedMeetings.count
            return profile
        }
        let negativePairs: [(UUID, [[Float]])] = snapshotIds.compactMap { id in
            guard let values = profiles[id]?.negativeExemplars, !values.isEmpty else { return nil }
            return (id, values)
        }
        let negatives = Dictionary(uniqueKeysWithValues: negativePairs)

        var pending = meeting.speakers.map { speaker -> PendingObservation in
            let floor = max(0, min(1, SpeakerEmbeddingThresholds.weSpeaker.adaptiveMatch(forSegmentCount: speaker.segmentCount) + config.matchFloorOffset))
            let match = Transcription.matchAgainstProfiles(
                speaker.embedding,
                profiles: snapshotProfiles,
                threshold: floor,
                negativeExemplarsByProfile: negatives
            )
            return PendingObservation(input: speaker, match: match, matchThreshold: floor)
        }

        // Mirror the production collision planner. A spun-off group becomes ASK; a fused group
        // inherits one identity. Because the cache already folds one row per ground-truth speaker,
        // any remaining fusion across rows is a measurable false-merge indicator.
        var matchedByIndex: [Int: UUID] = [:]
        var similarityByIndex: [Int: Double] = [:]
        var embeddingByIndex: [Int: [Float]] = [:]
        var segmentCountByIndex: [Int: Int] = [:]
        for i in pending.indices {
            embeddingByIndex[i] = pending[i].input.embedding
            segmentCountByIndex[i] = pending[i].input.segmentCount
            if let match = pending[i].match {
                matchedByIndex[i] = match.profileId
                similarityByIndex[i] = match.similarity
            }
        }
        let linkPlan = Transcription.planCrossClusterLinks(
            matchedProfileBySpeaker: matchedByIndex,
            matchSimilarityBySpeaker: similarityByIndex,
            meanBySpeaker: embeddingByIndex,
            segmentCountBySpeaker: segmentCountByIndex
        )
        func representative(for index: Int) -> Int {
            var cursor = index
            var visited: Set<Int> = []
            while let next = linkPlan.remaps[cursor], !visited.contains(cursor) {
                visited.insert(cursor)
                cursor = next
            }
            return cursor
        }
        let spunOff = Set(linkPlan.spinOffs)
        var representativeByIndex: [Int: Int] = [:]
        for i in pending.indices {
            let rep = representative(for: i)
            representativeByIndex[i] = rep
            if spunOff.contains(rep) {
                pending[i].match = nil
            } else if rep != i {
                pending[i].match = pending[rep].match
            }
        }

        let representativeIndices = pending.indices.filter { representativeByIndex[$0] == $0 }
        let memberIndices = pending.indices.filter { representativeByIndex[$0] != $0 }
        var resolvedIdByRepresentative: [Int: UUID] = [:]
        for index in representativeIndices + memberIndices {
            let observation = pending[index]
            let representativeIndex = representativeByIndex[index] ?? index
            let isRepresentative = representativeIndex == index
            let speaker = observation.input
            let scoresObservation = targetTruths.contains(speaker.gtSpeaker)
                && (condition?.contains(speaker) ?? true)
            let wasSeen = seenTruthsAtMeetingStart.contains(speaker.gtSpeaker)
            let galleryWasNonEmpty = !snapshotProfiles.isEmpty
            if scoresObservation {
                appearanceNumber[speaker.gtSpeaker, default: 0] += 1
                metrics.observations += 1
                if speaker.purity >= ResearchConstants.scoringPurityFloor { metrics.scorableObservations += 1 }
                if wasSeen { metrics.returningOpportunities += 1 }
                if !wasSeen && galleryWasNonEmpty { metrics.openSetTrials += 1 }
            }
            let currentAppearance = appearanceNumber[speaker.gtSpeaker] ?? 0

            // Every decision in one meeting reads the same frozen profile state. Production
            // matches and classifies against its pre-meeting snapshot, and fused member clusters
            // do not get a second chance to advance maturity after their representative writes.
            let matchedState = observation.match.flatMap { preMeetingProfiles[$0.profileId] }
            let predictedTruth = matchedState?.labelTruth
            let correct = predictedTruth.map { $0 == speaker.gtSpeaker }
            let decision: String
            if let match = observation.match, let state = matchedState,
               shouldAutoName(state: state, match: match, speaker: speaker, config: config) {
                decision = "auto"
            } else if matchedState != nil {
                decision = "suggest"
            } else {
                decision = "ask"
            }

            if scoresObservation { switch decision {
            case "auto":
                metrics.automaticNames += 1
                if speaker.purity < ResearchConstants.scoringPurityFloor { metrics.automaticNamesOnLowPurity += 1 }
                if correct == true {
                    metrics.correctAutomaticNames += 1
                    if !identitiesWithFirstAuto.contains(speaker.gtSpeaker) {
                        identitiesWithFirstAuto.insert(speaker.gtSpeaker)
                        metrics.identitiesReachingAuto += 1
                        metrics.firstAutoAppearanceTotal += currentAppearance
                        metrics.firstAutoConfirmedTotal += matchedState?.confirmedMeetings.count ?? 0
                    }
                } else {
                    metrics.falseAutomaticNamesAllPurities += 1
                    if speaker.purity >= ResearchConstants.scoringPurityFloor { metrics.falseAutomaticNames += 1 }
                    if !wasSeen && galleryWasNonEmpty { metrics.openSetFalseAutomaticNames += 1 }
                }
            case "suggest":
                metrics.suggestions += 1
                if wasSeen { metrics.repeatPrompts += 1 }
                if correct == false {
                    metrics.wrongSuggestions += 1
                    if !wasSeen && galleryWasNonEmpty { metrics.openSetWrongSuggestions += 1 }
                }
            default:
                metrics.asks += 1
                if wasSeen { metrics.repeatPrompts += 1 }
            } }

            let resolvedId: UUID
            if !isRepresentative,
               let inherited = resolvedIdByRepresentative[representativeIndex] {
                // Production removes remapped members from the write-back set. They inherit
                // the representative's final identity but never add another appearance,
                // confirmation, correction, or exemplar update.
                resolvedId = inherited
            } else if let match = observation.match, decision == "auto" {
                resolvedId = match.profileId
                applyMatchedAppearance(
                    profileId: match.profileId,
                    speaker: speaker,
                    match: match,
                    decision: decision,
                    correct: correct == true,
                    config: config,
                    profiles: &profiles
                )
                recordRecentOutcome(.autoAccepted, profileId: resolvedId, profiles: &profiles)
            } else if let match = observation.match, decision == "suggest", correct == true {
                resolvedId = match.profileId
                applyConfirmedSuggestion(
                    profileId: match.profileId,
                    speaker: speaker,
                    match: match,
                    meeting: meetingKey,
                    config: config,
                    profiles: &profiles
                )
            } else {
                if let match = observation.match, decision == "suggest" {
                    // Production restores the pre-write snapshot, records the rejected voice as a
                    // negative exemplar, and puts the wrong profile on probation.
                    profiles[match.profileId]?.negativeExemplars.append(speaker.embedding)
                    profiles[match.profileId]?.value.disputeCount += 1
                    recordRecentOutcome(.corrected, profileId: match.profileId, profiles: &profiles)
                }
                let reusedKnownProfile: Bool
                if let existing = profileForTruth[speaker.gtSpeaker] {
                    reusedKnownProfile = true
                    resolvedId = existing
                    if decision == "ask" {
                        applyUserConfirmedMerge(
                            profileId: existing,
                            speaker: speaker,
                            profiles: &profiles
                        )
                    } else {
                        applyUserConfirmedAppearance(
                            profileId: existing,
                            speaker: speaker,
                            config: config,
                            profiles: &profiles
                        )
                    }
                } else {
                    reusedKnownProfile = false
                    let id = deterministicProfileId(nextProfileNumber)
                    nextProfileNumber += 1
                    resolvedId = id
                    let now = Date(timeIntervalSince1970: Double(meeting.order + 1))
                    profiles[id] = SimulatedProfile(
                        value: SpeakerProfile(
                            id: id,
                            displayName: "truth:\(speaker.gtSpeaker)",
                            nameSource: NameSource.userManual,
                            embedding: SpeakerVectorMath.l2Normalize(speaker.embedding),
                            firstSeen: now,
                            lastSeen: now,
                            callCount: 1,
                            confidence: 0.5,
                            disputeCount: 0,
                            exemplars: []
                        ),
                        labelTruth: speaker.gtSpeaker,
                        appearanceCount: 1,
                        confirmedMeetings: [],
                        recentOutcomes: [],
                        negativeExemplars: [],
                        exemplarCounts: [],
                        observedTruths: [speaker.gtSpeaker]
                    )
                    profileForTruth[speaker.gtSpeaker] = id
                }
                confirm(profileId: resolvedId, meeting: meetingKey, profiles: &profiles)
                profiles[resolvedId]?.value.disputeCount = 0
                if decision == "ask" {
                    recordRecentOutcome(
                        reusedKnownProfile ? .merged : .named,
                        profileId: resolvedId,
                        profiles: &profiles
                    )
                }
            }
            if isRepresentative {
                resolvedIdByRepresentative[index] = resolvedId
                if scoresObservation {
                    scoredMutationProfileIds.insert(resolvedId)
                }
            }

            let predictedId = observation.match?.profileId ?? resolvedId
            if scoresObservation {
                predictedProfilesByTruth[speaker.gtSpeaker, default: []].insert(predictedId)
            }
            predictedMeetingsByProfileAndTruth[predictedId, default: [:]][
                speaker.gtSpeaker,
                default: []
            ].insert(meetingKey)
            if scoresObservation {
                scoredMeetingsByProfileAndTruth[predictedId, default: [:]][
                    speaker.gtSpeaker,
                    default: []
                ].insert(meetingKey)
            }

            if includeEvents && scoresObservation {
                events.append(TraceEvent(
                    corpus: cache.corpus,
                    meeting: meeting.meeting,
                    meetingOrder: meeting.order,
                    truthSpeaker: speaker.gtSpeaker,
                    purity: speaker.purity,
                    speechSeconds: speaker.durationSeconds,
                    segmentCount: speaker.segmentCount,
                    clusterCount: speaker.clusterCount,
                    decision: decision,
                    predictedProfileId: observation.match?.profileId,
                    predictedTruth: predictedTruth,
                    resolvedProfileId: resolvedId,
                    similarity: observation.match?.similarity,
                    secondBestSimilarity: observation.match?.secondBestSimilarity,
                    averageSimilarity: observation.match?.averageSimilarity,
                    secondBestAverageSimilarity: observation.match?.secondBestAverageSimilarity,
                    matchThreshold: observation.matchThreshold,
                    appearanceCountAtDecision: matchedState?.appearanceCount,
                    confirmedMeetingsAtDecision: matchedState?.confirmedMeetings.count,
                    correct: correct
                ))
            }
            seenTruths.insert(speaker.gtSpeaker)
        }
    }

    metrics.fragmentationExcess = predictedProfilesByTruth.values.reduce(0) { $0 + max(0, $1.count - 1) }
    metrics.contaminatedProfiles = profiles.values.filter {
        $0.observedTruths.count > 1 && scoredMutationProfileIds.contains($0.value.id)
    }.count
    metrics.profilesAtEnd = Set(predictedProfilesByTruth.values.flatMap { $0 }).count
    let falseMerges = falseMergeIndicators(
        predictedMeetingsByProfileAndTruth,
        scoredMeetingsByProfileAndTruth: scoredMeetingsByProfileAndTruth
    )
    metrics.withinMeetingFalseMergeIndicators = falseMerges.withinMeeting
    metrics.crossMeetingFalseMergeIndicators = falseMerges.crossMeeting
    return CacheEvaluation(metrics: metrics, events: events)
}

/// Count each contaminated (predicted profile, truth-speaker pair) exactly once.
/// A pair is within-meeting when the two truths ever shared a meeting; otherwise
/// it is cross-meeting. The buckets are intentionally disjoint so their sum is
/// a meaningful total instead of counting one collision twice.
func falseMergeIndicators(
    _ meetingsByProfileAndTruth: [UUID: [String: Set<String>]],
    scoredMeetingsByProfileAndTruth: [UUID: [String: Set<String>]]? = nil
) -> (withinMeeting: Int, crossMeeting: Int) {
    var withinMeeting = 0
    var crossMeeting = 0

    for (profileId, meetingsByTruth) in meetingsByProfileAndTruth {
        let truths = meetingsByTruth.keys.sorted()
        guard truths.count > 1 else { continue }
        for firstIndex in 0..<(truths.count - 1) {
            for secondIndex in (firstIndex + 1)..<truths.count {
                if let scoredMeetingsByProfileAndTruth {
                    let scoredByTruth = scoredMeetingsByProfileAndTruth[profileId] ?? [:]
                    let firstWasScored = !(scoredByTruth[truths[firstIndex]]?.isEmpty ?? true)
                    let secondWasScored = !(scoredByTruth[truths[secondIndex]]?.isEmpty ?? true)
                    if !firstWasScored && !secondWasScored {
                        continue
                    }
                }
                let firstMeetings = meetingsByTruth[truths[firstIndex]] ?? []
                let secondMeetings = meetingsByTruth[truths[secondIndex]] ?? []
                if firstMeetings.isDisjoint(with: secondMeetings) {
                    crossMeeting += 1
                } else {
                    withinMeeting += 1
                }
            }
        }
    }
    return (withinMeeting, crossMeeting)
}

func shouldAutoName(
    state: SimulatedProfile,
    match: Transcription.SnapshotMatchResult,
    speaker: FingerprintSpeaker,
    config: AutoResearchConfig
) -> Bool {
    let maturity = config.autoMaturityEvidence == .appearances
        ? state.appearanceCount : state.confirmedMeetings.count
    let runner = match.secondBestAverageSimilarity
    let marginOK = runner < 0 || (match.averageSimilarity - runner) >= config.autoMargin
    let averageOK = config.minimumAverageSimilarity < 0
        || match.averageSimilarity >= config.minimumAverageSimilarity
    let health = SpeakerProfileHealth.assess(
        disputeCount: state.value.disputeCount,
        recentOutcomes: state.recentOutcomes
    )
    let decision = state.value.displayName?.isEmpty == false
        && health == .trusted
        && maturity >= config.requiredMaturityCount
        && match.similarity > config.autoSimilarity
        && marginOK
        && averageOK
        && speaker.durationSeconds >= config.minimumSpeechSeconds
        && speaker.segmentCount >= config.minimumSegmentCount

    if config == .productionBaseline {
        var profile = state.value
        profile.callCount = state.appearanceCount
        profile.confirmedMeetingCount = state.confirmedMeetings.count
        let production = SpeakerNamingPolicy.shouldAutoAccept(
            profile: profile,
            similarity: match.similarity,
            secondBestSimilarity: match.secondBestSimilarity,
            recentOutcomes: state.recentOutcomes,
            marginSimilarities: (match.averageSimilarity, match.secondBestAverageSimilarity)
        )
        precondition(production == decision, "baseline policy parity failure")
    }
    return decision
}

func applyConfirmedSuggestion(
    profileId: UUID,
    speaker: FingerprintSpeaker,
    match: Transcription.SnapshotMatchResult,
    meeting: String,
    config: AutoResearchConfig,
    profiles: inout [UUID: SimulatedProfile]
) {
    applyMatchedAppearance(
        profileId: profileId,
        speaker: speaker,
        match: match,
        decision: "suggest",
        correct: true,
        config: config,
        profiles: &profiles
    )
    confirm(profileId: profileId, meeting: meeting, profiles: &profiles)
    // Production treats a correct confirmation as an explicit repair.
    profiles[profileId]?.value.disputeCount = 0
    recordRecentOutcome(.confirmed, profileId: profileId, profiles: &profiles)
}

private func applyMatchedAppearance(
    profileId: UUID,
    speaker: FingerprintSpeaker,
    match: Transcription.SnapshotMatchResult,
    decision: String,
    correct: Bool,
    config: AutoResearchConfig,
    profiles: inout [UUID: SimulatedProfile]
) {
    guard var state = profiles[profileId] else { return }
    state.appearanceCount += 1
    state.value.callCount = state.appearanceCount
    state.observedTruths.insert(speaker.gtSpeaker)
    let evidenceAllowsBlend: Bool
    switch config.writeBackEvidence {
    case .production:
        evidenceAllowsBlend = true
    case .confirmedOrAuto:
        evidenceAllowsBlend = decision == "auto" || (decision == "suggest" && correct)
    case .confirmedOnly:
        evidenceAllowsBlend = decision == "suggest" && correct
    }
    let alpha = evidenceAllowsBlend
        ? blendAlpha(similarity: match.similarity, secondBest: match.secondBestSimilarity, config: config)
        : 0
    if alpha > 0 {
        state.value.embedding = blend(state.value.embedding, speaker.embedding, alpha: alpha)
        updateExemplars(state: &state, incoming: speaker.embedding, config: config)
    }
    profiles[profileId] = state
}

private func applyUserConfirmedAppearance(
    profileId: UUID,
    speaker: FingerprintSpeaker,
    config: AutoResearchConfig,
    profiles: inout [UUID: SimulatedProfile]
) {
    guard var state = profiles[profileId] else { return }
    state.appearanceCount += 1
    state.value.callCount = state.appearanceCount
    state.value.embedding = blend(state.value.embedding, speaker.embedding, alpha: config.confidentBlendAlpha)
    state.observedTruths.insert(speaker.gtSpeaker)
    updateExemplars(state: &state, incoming: speaker.embedding, config: config)
    profiles[profileId] = state
}

/// Production ASK parity: an unmatched observation first creates a one-call
/// temporary profile, then the user's known-person choice merges that profile
/// into the existing keeper using call-count weights. Structural merges clear
/// the keeper's exemplar cache and add the production confidence bump.
func applyUserConfirmedMerge(
    profileId: UUID,
    speaker: FingerprintSpeaker,
    profiles: inout [UUID: SimulatedProfile]
) {
    guard var state = profiles[profileId] else { return }
    let mergedCallCount = state.appearanceCount + 1
    state.value.embedding = blend(
        state.value.embedding,
        speaker.embedding,
        alpha: 1 / Float(mergedCallCount)
    )
    state.appearanceCount = mergedCallCount
    state.value.callCount = mergedCallCount
    state.value.confidence = min(1, state.value.confidence + 0.15)
    state.value.exemplars = []
    state.exemplarCounts = []
    state.observedTruths.insert(speaker.gtSpeaker)
    profiles[profileId] = state
}

private func confirm(
    profileId: UUID,
    meeting: String,
    profiles: inout [UUID: SimulatedProfile]
) {
    guard var state = profiles[profileId] else { return }
    state.confirmedMeetings.insert(meeting)
    state.value.confirmedMeetingCount = state.confirmedMeetings.count
    profiles[profileId] = state
}

private func recordRecentOutcome(
    _ outcome: SpeakerMatchOutcomeKind,
    profileId: UUID,
    profiles: inout [UUID: SimulatedProfile]
) {
    guard var state = profiles[profileId] else { return }
    state.recentOutcomes.insert(outcome, at: 0)
    if state.recentOutcomes.count > SpeakerProfileHealth.recentOutcomeWindow {
        state.recentOutcomes.removeLast(
            state.recentOutcomes.count - SpeakerProfileHealth.recentOutcomeWindow
        )
    }
    profiles[profileId] = state
}

func blendAlpha(
    similarity: Double,
    secondBest: Double,
    config: AutoResearchConfig
) -> Float {
    if secondBest >= 0, similarity - secondBest < config.writeBackMargin { return 0 }
    if similarity >= config.confidentWriteSimilarity { return config.confidentBlendAlpha }
    if similarity >= config.cautiousWriteSimilarity { return config.cautiousBlendAlpha }
    return 0
}

func blend(_ existing: [Float], _ incoming: [Float], alpha: Float) -> [Float] {
    guard existing.count == incoming.count else { return existing }
    let bounded = max(0, min(1, alpha))
    return SpeakerVectorMath.l2Normalize(zip(existing, incoming).map { old, new in
        old * (1 - bounded) + new * bounded
    })
}

func updateExemplars(
    state: inout SimulatedProfile,
    incoming: [Float],
    config: AutoResearchConfig
) {
    guard config.maximumExemplars > 0, incoming.count == state.value.embedding.count else {
        state.value.exemplars = []
        state.exemplarCounts = []
        return
    }
    var exemplars = state.value.exemplars
    var counts = state.exemplarCounts
    while counts.count < exemplars.count { counts.append(1) }
    let averageSimilarity = SpeakerVectorMath.cosineSimilarity(incoming, state.value.embedding)
    var bestSimilarity = averageSimilarity
    var bestIndex: Int?
    for i in exemplars.indices {
        let similarity = SpeakerVectorMath.cosineSimilarity(incoming, exemplars[i])
        if similarity > bestSimilarity { bestSimilarity = similarity; bestIndex = i }
    }
    if bestSimilarity >= config.exemplarSameConditionSimilarity {
        if let bestIndex {
            exemplars[bestIndex] = blend(exemplars[bestIndex], incoming, alpha: config.exemplarBlendAlpha)
            counts[bestIndex] += 1
        }
    } else if exemplars.count < config.maximumExemplars {
        exemplars.append(SpeakerVectorMath.l2Normalize(incoming))
        counts.append(1)
    } else if let victim = mostRedundantExemplar(exemplars, average: state.value.embedding),
              victim.similarity > bestSimilarity {
        exemplars[victim.index] = SpeakerVectorMath.l2Normalize(incoming)
        counts[victim.index] = 1
    }
    state.value.exemplars = exemplars
    state.exemplarCounts = counts
}

private func mostRedundantExemplar(
    _ exemplars: [[Float]],
    average: [Float]
) -> (index: Int, similarity: Double)? {
    guard !exemplars.isEmpty else { return nil }
    var result = (index: 0, similarity: -Double.infinity)
    for i in exemplars.indices {
        var similarity = SpeakerVectorMath.cosineSimilarity(exemplars[i], average)
        for j in exemplars.indices where i != j {
            similarity = max(similarity, SpeakerVectorMath.cosineSimilarity(exemplars[i], exemplars[j]))
        }
        if similarity > result.similarity { result = (i, similarity) }
    }
    return result
}

// MARK: - Stable identity split

func corpusFamily(_ corpus: String) -> String {
    if corpus.hasPrefix("ami_") { return "ami" }
    if corpus.hasPrefix("voxceleb_") { return "voxceleb" }
    if corpus.hasPrefix("voxconverse_") { return "voxconverse" }
    return corpus.split(separator: "_").first.map(String.init) ?? corpus
}

func identitySplit(family: String, truth: String) -> ResearchSplit {
    let bucket = stableFNV1a("\(family)|\(truth)") % 10
    switch bucket {
    case 0...5: return .train
    case 6...7: return .dev
    default: return .holdout
    }
}

private func stableFNV1a(_ value: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return hash
}

func deterministicProfileId(_ value: UInt64) -> UUID {
    let suffix = String(format: "%012llx", value)
    return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
}

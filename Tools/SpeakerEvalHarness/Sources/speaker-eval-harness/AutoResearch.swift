import Foundation
import CryptoKit
import TranscriptedCore

// MARK: - Frozen fingerprint input

private struct FingerprintSpeaker: Decodable {
    let gtSpeaker: String
    let embedding: [Float]
    let durationSeconds: Double
    let segmentCount: Int
    let clusterCount: Int
    let purity: Double
}

private struct FingerprintMeeting: Decodable {
    let meeting: String
    let order: Int
    let speakers: [FingerprintSpeaker]
}

private struct FingerprintCache: Decodable {
    let corpus: String
    let meetings: [FingerprintMeeting]
}

private enum ResearchSplit: String, Codable, CaseIterable {
    case train
    case dev
    case holdout
    case all
}

private enum MaturityEvidence: String, Codable {
    case appearances
    case confirmedMeetings = "confirmed_meetings"
}

private enum WriteBackEvidence: String, Codable {
    /// Current production behavior: every accepted DB match records an appearance and may blend.
    case production
    /// Defer suggest-path blending until the user confirms it; auto-name still adapts.
    case confirmedOrAuto = "confirmed_or_auto"
    /// Only an explicit user confirmation may change the voiceprint.
    case confirmedOnly = "confirmed_only"
}

private struct AutoResearchConfig: Codable, Equatable {
    let id: String
    let autoMaturityEvidence: MaturityEvidence
    let matchMaturityEvidence: MaturityEvidence
    let requiredMaturityCount: Int
    let autoSimilarity: Double
    let autoMargin: Double
    let minimumAverageSimilarity: Double
    let minimumSpeechSeconds: Double
    let minimumSegmentCount: Int
    let matchFloorOffset: Double
    let writeBackEvidence: WriteBackEvidence
    let writeBackMargin: Double
    let confidentWriteSimilarity: Double
    let cautiousWriteSimilarity: Double
    let confidentBlendAlpha: Float
    let cautiousBlendAlpha: Float
    let maximumExemplars: Int
    let exemplarSameConditionSimilarity: Double
    let exemplarBlendAlpha: Float

    static let productionBaseline = AutoResearchConfig(
        id: "baseline-production",
        autoMaturityEvidence: .confirmedMeetings,
        matchMaturityEvidence: .appearances,
        requiredMaturityCount: SpeakerNamingPolicy.requiredConfirmedMeetings,
        autoSimilarity: SpeakerNamingPolicy.autoAcceptSimilarityThreshold,
        autoMargin: SpeakerNamingPolicy.autoAcceptMarginMin,
        minimumAverageSimilarity: -1,
        minimumSpeechSeconds: 0,
        minimumSegmentCount: 0,
        matchFloorOffset: 0,
        writeBackEvidence: .production,
        writeBackMargin: SpeakerWritePathPolicy.writeBackMarginMin,
        confidentWriteSimilarity: SpeakerWritePathPolicy.confidentWriteBackSimilarity,
        cautiousWriteSimilarity: SpeakerWritePathPolicy.cautiousWriteBackSimilarity,
        confidentBlendAlpha: SpeakerWritePathPolicy.confidentBlendAlpha,
        cautiousBlendAlpha: SpeakerWritePathPolicy.cautiousBlendAlpha,
        maximumExemplars: SpeakerExemplarPolicy.maxExemplars,
        exemplarSameConditionSimilarity: SpeakerExemplarPolicy.sameConditionSimilarity,
        exemplarBlendAlpha: SpeakerExemplarPolicy.exemplarBlendAlpha
    )
}

private struct ConfigEnvelope: Decodable {
    let configs: [AutoResearchConfig]
}

// MARK: - Report schema

private struct MetricSnapshot: Codable {
    let observations: Int
    let scorableObservations: Int
    let recurringSpeakerUnits: Int
    let returningOpportunities: Int
    let asks: Int
    let suggestions: Int
    let automaticNames: Int
    let correctAutomaticNames: Int
    let falseAutomaticNames: Int
    let falseAutomaticNamesAllPurities: Int
    let automaticNamesOnLowPurity: Int
    let wrongSuggestions: Int
    let repeatPrompts: Int
    let openSetTrials: Int
    let openSetFalseAutomaticNames: Int
    let openSetWrongSuggestions: Int
    let falseMergeIndicators: Int
    let withinMeetingFalseMergeIndicators: Int
    let crossMeetingFalseMergeIndicators: Int
    let fragmentationExcess: Int
    let contaminatedProfiles: Int
    let profilesAtEnd: Int
    let identitiesReachingAuto: Int
    let meanAppearanceToFirstAuto: Double?
    let meanConfirmedMeetingsAtFirstAuto: Double?
    let promptsPerRecurringSpeaker: Double?
    let autoCoverage: Double?
    let autoPrecision: Double?
    let falseAutoUpper95WhenZero: Double?
}

private struct TraceEvent: Codable {
    let corpus: String
    let meeting: String
    let meetingOrder: Int
    let truthSpeaker: String
    let purity: Double
    let speechSeconds: Double
    let segmentCount: Int
    let clusterCount: Int
    let decision: String
    let predictedProfileId: UUID?
    let predictedTruth: String?
    let resolvedProfileId: UUID
    let similarity: Double?
    let secondBestSimilarity: Double?
    let averageSimilarity: Double?
    let secondBestAverageSimilarity: Double?
    let matchThreshold: Double
    let appearanceCountAtDecision: Int?
    let confirmedMeetingsAtDecision: Int?
    let correct: Bool?
}

private struct ConfigReport: Codable {
    let config: AutoResearchConfig
    let metrics: MetricSnapshot
    let slices: [String: MetricSnapshot]
    let events: [TraceEvent]?
}

private struct AutoResearchReport: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let split: ResearchSplit
    let manifestPath: String
    let inputRoot: String
    let scoringPurityFloor: Double
    let splitContract: String
    let reports: [ConfigReport]
}

// MARK: - Mutable simulation state

private struct SimulatedProfile {
    var value: SpeakerProfile
    let labelTruth: String
    var appearanceCount: Int
    var confirmedMeetings: Set<String>
    /// Most-recent-first, matching `SpeakerDatabase.recentMatchOutcomes`.
    var recentOutcomes: [SpeakerMatchOutcomeKind]
    var negativeExemplars: [[Float]]
    var exemplarCounts: [Int]
    var observedTruths: Set<String>
}

private struct MutableMetrics {
    var observations = 0
    var scorableObservations = 0
    var recurringSpeakerUnits = 0
    var returningOpportunities = 0
    var asks = 0
    var suggestions = 0
    var automaticNames = 0
    var correctAutomaticNames = 0
    var falseAutomaticNames = 0
    var falseAutomaticNamesAllPurities = 0
    var automaticNamesOnLowPurity = 0
    var wrongSuggestions = 0
    var repeatPrompts = 0
    var openSetTrials = 0
    var openSetFalseAutomaticNames = 0
    var openSetWrongSuggestions = 0
    var withinMeetingFalseMergeIndicators = 0
    var crossMeetingFalseMergeIndicators = 0
    var fragmentationExcess = 0
    var contaminatedProfiles = 0
    var profilesAtEnd = 0
    var firstAutoAppearanceTotal = 0
    var firstAutoConfirmedTotal = 0
    var identitiesReachingAuto = 0

    mutating func merge(_ other: MutableMetrics) {
        observations += other.observations
        scorableObservations += other.scorableObservations
        recurringSpeakerUnits += other.recurringSpeakerUnits
        returningOpportunities += other.returningOpportunities
        asks += other.asks
        suggestions += other.suggestions
        automaticNames += other.automaticNames
        correctAutomaticNames += other.correctAutomaticNames
        falseAutomaticNames += other.falseAutomaticNames
        falseAutomaticNamesAllPurities += other.falseAutomaticNamesAllPurities
        automaticNamesOnLowPurity += other.automaticNamesOnLowPurity
        wrongSuggestions += other.wrongSuggestions
        repeatPrompts += other.repeatPrompts
        openSetTrials += other.openSetTrials
        openSetFalseAutomaticNames += other.openSetFalseAutomaticNames
        openSetWrongSuggestions += other.openSetWrongSuggestions
        withinMeetingFalseMergeIndicators += other.withinMeetingFalseMergeIndicators
        crossMeetingFalseMergeIndicators += other.crossMeetingFalseMergeIndicators
        fragmentationExcess += other.fragmentationExcess
        contaminatedProfiles += other.contaminatedProfiles
        profilesAtEnd += other.profilesAtEnd
        firstAutoAppearanceTotal += other.firstAutoAppearanceTotal
        firstAutoConfirmedTotal += other.firstAutoConfirmedTotal
        identitiesReachingAuto += other.identitiesReachingAuto
    }

    func snapshot() -> MetricSnapshot {
        let promptsPerSpeaker = recurringSpeakerUnits > 0
            ? Double(repeatPrompts) / Double(recurringSpeakerUnits) : nil
        let coverage = returningOpportunities > 0
            ? Double(correctAutomaticNames) / Double(returningOpportunities) : nil
        let precision = automaticNames > 0
            ? Double(automaticNames - falseAutomaticNames) / Double(automaticNames) : nil
        let firstAuto = identitiesReachingAuto > 0
            ? Double(firstAutoAppearanceTotal) / Double(identitiesReachingAuto) : nil
        let firstAutoConfirmed = identitiesReachingAuto > 0
            ? Double(firstAutoConfirmedTotal) / Double(identitiesReachingAuto) : nil
        let upper = falseAutomaticNames == 0 && automaticNames > 0
            ? min(1, 3.0 / Double(automaticNames)) : nil
        return MetricSnapshot(
            observations: observations,
            scorableObservations: scorableObservations,
            recurringSpeakerUnits: recurringSpeakerUnits,
            returningOpportunities: returningOpportunities,
            asks: asks,
            suggestions: suggestions,
            automaticNames: automaticNames,
            correctAutomaticNames: correctAutomaticNames,
            falseAutomaticNames: falseAutomaticNames,
            falseAutomaticNamesAllPurities: falseAutomaticNamesAllPurities,
            automaticNamesOnLowPurity: automaticNamesOnLowPurity,
            wrongSuggestions: wrongSuggestions,
            repeatPrompts: repeatPrompts,
            openSetTrials: openSetTrials,
            openSetFalseAutomaticNames: openSetFalseAutomaticNames,
            openSetWrongSuggestions: openSetWrongSuggestions,
            falseMergeIndicators: withinMeetingFalseMergeIndicators + crossMeetingFalseMergeIndicators,
            withinMeetingFalseMergeIndicators: withinMeetingFalseMergeIndicators,
            crossMeetingFalseMergeIndicators: crossMeetingFalseMergeIndicators,
            fragmentationExcess: fragmentationExcess,
            contaminatedProfiles: contaminatedProfiles,
            profilesAtEnd: profilesAtEnd,
            identitiesReachingAuto: identitiesReachingAuto,
            meanAppearanceToFirstAuto: firstAuto,
            meanConfirmedMeetingsAtFirstAuto: firstAutoConfirmed,
            promptsPerRecurringSpeaker: promptsPerSpeaker,
            autoCoverage: coverage,
            autoPrecision: precision,
            falseAutoUpper95WhenZero: upper
        )
    }
}

private struct PendingObservation {
    let input: FingerprintSpeaker
    var match: Transcription.SnapshotMatchResult?
    let matchThreshold: Double
}

private struct CacheEvaluation {
    var metrics: MutableMetrics
    var events: [TraceEvent]
}

private struct AccumulatedConfig {
    var metrics = MutableMetrics()
    var slices: [String: MutableMetrics] = [:]
    var events: [TraceEvent] = []
}

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
        schemaVersion: 2,
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

private func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: - Chronological replay

private enum ResearchConstants {
    static let scoringPurityFloor = 0.80
}

private func evaluate(
    cache: FingerprintCache,
    config: AutoResearchConfig,
    split: ResearchSplit,
    includeEvents: Bool
) -> CacheEvaluation {
    let family = corpusFamily(cache.corpus)
    let orderedMeetings = cache.meetings.sorted {
        ($0.order, $0.meeting) < ($1.order, $1.meeting)
    }
    let filteredMeetings = orderedMeetings.map { meeting in
        FingerprintMeeting(
            meeting: meeting.meeting,
            order: meeting.order,
            speakers: meeting.speakers.filter { split == .all || identitySplit(family: family, truth: $0.gtSpeaker) == split }
        )
    }
    let appearances = Dictionary(grouping: filteredMeetings.flatMap(\.speakers), by: \.gtSpeaker).mapValues(\.count)

    var metrics = MutableMetrics()
    metrics.recurringSpeakerUnits = appearances.values.filter { $0 >= 2 }.count
    var profiles: [UUID: SimulatedProfile] = [:]
    var profileForTruth: [String: UUID] = [:]
    var seenTruths: Set<String> = []
    var appearanceNumber: [String: Int] = [:]
    var identitiesWithFirstAuto: Set<String> = []
    var predictedProfilesByTruth: [String: Set<UUID>] = [:]
    var predictedMeetingsByProfileAndTruth: [UUID: [String: Set<String>]] = [:]
    var events: [TraceEvent] = []
    var nextProfileNumber: UInt64 = 1

    for meeting in filteredMeetings where !meeting.speakers.isEmpty {
        let meetingKey = "\(cache.corpus):\(meeting.meeting)"
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
        for i in pending.indices {
            let rep = representative(for: i)
            if spunOff.contains(rep) {
                pending[i].match = nil
            } else if rep != i {
                pending[i].match = pending[rep].match
            }
        }

        for observation in pending {
            let speaker = observation.input
            let wasSeen = seenTruths.contains(speaker.gtSpeaker)
            let galleryWasNonEmpty = !snapshotProfiles.isEmpty
            appearanceNumber[speaker.gtSpeaker, default: 0] += 1
            let currentAppearance = appearanceNumber[speaker.gtSpeaker]!
            metrics.observations += 1
            if speaker.purity >= ResearchConstants.scoringPurityFloor { metrics.scorableObservations += 1 }
            if wasSeen { metrics.returningOpportunities += 1 }
            if !wasSeen && galleryWasNonEmpty { metrics.openSetTrials += 1 }

            let matchedState = observation.match.flatMap { profiles[$0.profileId] }
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

            switch decision {
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
            }

            let resolvedId: UUID
            if let match = observation.match, decision == "auto" {
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

            let predictedId = observation.match?.profileId ?? resolvedId
            predictedProfilesByTruth[speaker.gtSpeaker, default: []].insert(predictedId)
            predictedMeetingsByProfileAndTruth[predictedId, default: [:]][
                speaker.gtSpeaker,
                default: []
            ].insert(meetingKey)

            if includeEvents {
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
    metrics.contaminatedProfiles = profiles.values.filter { $0.observedTruths.count > 1 }.count
    metrics.profilesAtEnd = profiles.count
    let falseMerges = falseMergeIndicators(predictedMeetingsByProfileAndTruth)
    metrics.withinMeetingFalseMergeIndicators = falseMerges.withinMeeting
    metrics.crossMeetingFalseMergeIndicators = falseMerges.crossMeeting
    return CacheEvaluation(metrics: metrics, events: events)
}

/// Count each contaminated (predicted profile, truth-speaker pair) exactly once.
/// A pair is within-meeting when the two truths ever shared a meeting; otherwise
/// it is cross-meeting. The buckets are intentionally disjoint so their sum is
/// a meaningful total instead of counting one collision twice.
private func falseMergeIndicators(
    _ meetingsByProfileAndTruth: [UUID: [String: Set<String>]]
) -> (withinMeeting: Int, crossMeeting: Int) {
    var withinMeeting = 0
    var crossMeeting = 0

    for meetingsByTruth in meetingsByProfileAndTruth.values {
        let truths = meetingsByTruth.keys.sorted()
        guard truths.count > 1 else { continue }
        for firstIndex in 0..<(truths.count - 1) {
            for secondIndex in (firstIndex + 1)..<truths.count {
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

private func shouldAutoName(
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

private func applyConfirmedSuggestion(
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
private func applyUserConfirmedMerge(
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

/// Cheap parity checks run by the verification matrix. These exercise the two
/// failure modes most likely to make an offline sweep disagree with production:
/// correction probation and confirmation-driven repair.
func runAutoResearchSelfTests() {
    let profileId = deterministicProfileId(1)
    let embedding: [Float] = [1, 0]
    let profile = SpeakerProfile(
        id: profileId,
        displayName: "truth:test",
        nameSource: NameSource.userManual,
        embedding: embedding,
        firstSeen: Date(timeIntervalSince1970: 1),
        lastSeen: Date(timeIntervalSince1970: 1),
        callCount: 8,
        confidence: 0.9,
        disputeCount: 0,
        confirmedMeetingCount: SpeakerNamingPolicy.requiredConfirmedMeetings,
        exemplars: []
    )
    let confirmedMeetings = Set(
        (1...SpeakerNamingPolicy.requiredConfirmedMeetings).map { "meeting-\($0)" }
    )
    let speaker = FingerprintSpeaker(
        gtSpeaker: "test",
        embedding: embedding,
        durationSeconds: 10,
        segmentCount: 4,
        clusterCount: 1,
        purity: 1
    )
    let match = Transcription.SnapshotMatchResult(
        profileId: profileId,
        similarity: 0.99,
        secondBestSimilarity: -1,
        averageSimilarity: 0.99,
        secondBestAverageSimilarity: -1
    )
    var correctedState = SimulatedProfile(
        value: profile,
        labelTruth: "test",
        appearanceCount: 8,
        confirmedMeetings: confirmedMeetings,
        recentOutcomes: [.corrected],
        negativeExemplars: [],
        exemplarCounts: [],
        observedTruths: ["test"]
    )
    guard !shouldAutoName(
        state: correctedState,
        match: match,
        speaker: speaker,
        config: .productionBaseline
    ) else {
        die("autoeval self-test failed: a recent correction did not force probation")
    }

    correctedState.recentOutcomes = [.confirmed, .corrected]
    guard shouldAutoName(
        state: correctedState,
        match: match,
        speaker: speaker,
        config: .productionBaseline
    ) else {
        die("autoeval self-test failed: a later confirmation did not restore trust")
    }

    correctedState.value.disputeCount = 2
    var profiles = [profileId: correctedState]
    applyConfirmedSuggestion(
        profileId: profileId,
        speaker: speaker,
        match: match,
        meeting: "repair-meeting",
        config: .productionBaseline,
        profiles: &profiles
    )
    guard profiles[profileId]?.value.disputeCount == 0,
          profiles[profileId]?.recentOutcomes.first == .confirmed else {
        die("autoeval self-test failed: confirmation did not repair profile state")
    }

    var mergeState = correctedState
    mergeState.value.confidence = 0.5
    mergeState.value.exemplars = [[0, 1]]
    mergeState.exemplarCounts = [2]
    profiles = [profileId: mergeState]
    let unmatchedSpeaker = FingerprintSpeaker(
        gtSpeaker: "test",
        embedding: [0, 1],
        durationSeconds: 10,
        segmentCount: 4,
        clusterCount: 1,
        purity: 1
    )
    applyUserConfirmedMerge(
        profileId: profileId,
        speaker: unmatchedSpeaker,
        profiles: &profiles
    )
    let expectedMergeEmbedding = blend(embedding, unmatchedSpeaker.embedding, alpha: 1 / 9)
    guard let merged = profiles[profileId],
          merged.appearanceCount == 9,
          abs(merged.value.confidence - 0.65) < 0.0001,
          merged.value.exemplars.isEmpty,
          merged.exemplarCounts.isEmpty,
          zip(merged.value.embedding, expectedMergeEmbedding).allSatisfy({ pair in
              abs(pair.0 - pair.1) < 0.0001
          }) else {
        die("autoeval self-test failed: unmatched ASK did not mirror production merge semantics")
    }
    let collisionProfile = deterministicProfileId(2)
    let secondCollisionProfile = deterministicProfileId(3)
    let falseMerges = falseMergeIndicators([
        collisionProfile: [
            "A": Set(["meeting-1", "meeting-1", "meeting-2"]),
            "B": ["meeting-2", "meeting-3"],
            "C": ["meeting-3", "meeting-4"],
            "D": ["meeting-1", "meeting-4"],
        ],
        secondCollisionProfile: [
            "E": ["meeting-5"],
            "F": ["meeting-6"],
        ],
    ])
    var bucketMetrics = MutableMetrics()
    bucketMetrics.withinMeetingFalseMergeIndicators = falseMerges.withinMeeting
    bucketMetrics.crossMeetingFalseMergeIndicators = falseMerges.crossMeeting
    let bucketSnapshot = bucketMetrics.snapshot()
    guard falseMerges.withinMeeting == 4,
          falseMerges.crossMeeting == 3,
          bucketSnapshot.falseMergeIndicators == 7,
          bucketSnapshot.falseMergeIndicators
            == bucketSnapshot.withinMeetingFalseMergeIndicators
                + bucketSnapshot.crossMeetingFalseMergeIndicators else {
        die("autoeval self-test failed: false-merge buckets overlap or omit a truth pair")
    }
    print("AUTOEVAL_SELF_TEST PASS")
}

private func blendAlpha(
    similarity: Double,
    secondBest: Double,
    config: AutoResearchConfig
) -> Float {
    if secondBest >= 0, similarity - secondBest < config.writeBackMargin { return 0 }
    if similarity >= config.confidentWriteSimilarity { return config.confidentBlendAlpha }
    if similarity >= config.cautiousWriteSimilarity { return config.cautiousBlendAlpha }
    return 0
}

private func blend(_ existing: [Float], _ incoming: [Float], alpha: Float) -> [Float] {
    guard existing.count == incoming.count else { return existing }
    let bounded = max(0, min(1, alpha))
    return SpeakerVectorMath.l2Normalize(zip(existing, incoming).map { old, new in
        old * (1 - bounded) + new * bounded
    })
}

private func updateExemplars(
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

private func corpusFamily(_ corpus: String) -> String {
    if corpus.hasPrefix("ami_") { return "ami" }
    if corpus.hasPrefix("voxceleb_") { return "voxceleb" }
    if corpus.hasPrefix("voxconverse_") { return "voxconverse" }
    return corpus.split(separator: "_").first.map(String.init) ?? corpus
}

private func identitySplit(family: String, truth: String) -> ResearchSplit {
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

private func deterministicProfileId(_ value: UInt64) -> UUID {
    let suffix = String(format: "%012llx", value)
    return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
}

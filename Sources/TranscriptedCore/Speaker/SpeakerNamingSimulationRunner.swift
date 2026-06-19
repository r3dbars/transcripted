import Foundation

@available(macOS 14.0, *)
public struct SpeakerNamingSimulationKnownSpeaker: Sendable {
    public let displayName: String
    public let embedding: [Float]
    public let callCount: Int
    public let confidence: Double

    public init(
        displayName: String,
        embedding: [Float],
        callCount: Int = 6,
        confidence: Double = 0.9
    ) {
        self.displayName = displayName
        self.embedding = embedding
        self.callCount = max(1, callCount)
        self.confidence = confidence
    }
}

@available(macOS 14.0, *)
public struct SpeakerNamingSimulationSegment: Sendable {
    public let channel: UtteranceChannel
    public let diarizerSpeakerId: Int
    public let truthSpeakerId: String
    public let expectedDisplayName: String
    public let text: String
    public let start: TimeInterval
    public let duration: TimeInterval
    public let embedding: [Float]?
    public let qualityScore: Float
    public let includeInTranscript: Bool

    public init(
        channel: UtteranceChannel,
        diarizerSpeakerId: Int,
        truthSpeakerId: String,
        expectedDisplayName: String,
        text: String,
        start: TimeInterval,
        duration: TimeInterval = 2.0,
        embedding: [Float]? = nil,
        qualityScore: Float = 0.95,
        includeInTranscript: Bool = true
    ) {
        self.channel = channel
        self.diarizerSpeakerId = diarizerSpeakerId
        self.truthSpeakerId = truthSpeakerId
        self.expectedDisplayName = expectedDisplayName
        self.text = text
        self.start = start
        self.duration = duration
        self.embedding = embedding
        self.qualityScore = qualityScore
        self.includeInTranscript = includeInTranscript
    }
}

@available(macOS 14.0, *)
public enum SpeakerNamingSimulationAction: Sendable {
    case name(channel: UtteranceChannel, diarizerSpeakerId: Int, as: String)
    case confirm(channel: UtteranceChannel, diarizerSpeakerId: Int, as: String)
    case correct(channel: UtteranceChannel, diarizerSpeakerId: Int, from: String?, to: String)
    case merge(channel: UtteranceChannel, diarizerSpeakerId: Int, intoDisplayName: String)
    case discard(channel: UtteranceChannel, diarizerSpeakerId: Int)
    case collapseMicToYou
    case deferAll
    case cancelBeforeNaming
}

@available(macOS 14.0, *)
public enum SpeakerNamingSimulationPostAction: Sendable {
    case nameDeferred(channel: UtteranceChannel, diarizerSpeakerId: Int, as: String)
    case renameProfile(channel: UtteranceChannel, diarizerSpeakerId: Int, to: String)
    case mergeProfile(channel: UtteranceChannel, diarizerSpeakerId: Int, intoDisplayName: String)
}

@available(macOS 14.0, *)
public struct SpeakerNamingSimulationMeeting: Sendable {
    public let id: String
    public let title: String
    public let segments: [SpeakerNamingSimulationSegment]
    public let actions: [SpeakerNamingSimulationAction]
    public let postActions: [SpeakerNamingSimulationPostAction]
    public let replacementTargetMeetingId: String?
    public let pairwiseMergeThreshold: Float?
    public let recordingDate: Date

    public init(
        id: String,
        title: String,
        segments: [SpeakerNamingSimulationSegment],
        actions: [SpeakerNamingSimulationAction] = [],
        postActions: [SpeakerNamingSimulationPostAction] = [],
        replacementTargetMeetingId: String? = nil,
        pairwiseMergeThreshold: Float? = nil,
        recordingDate: Date = Date(timeIntervalSince1970: 1_781_452_800)
    ) {
        self.id = id
        self.title = title
        self.segments = segments
        self.actions = actions
        self.postActions = postActions
        self.replacementTargetMeetingId = replacementTargetMeetingId
        self.pairwiseMergeThreshold = pairwiseMergeThreshold
        self.recordingDate = recordingDate
    }
}

@available(macOS 14.0, *)
public struct SpeakerNamingSimulationSuite: Sendable {
    public let name: String
    public let knownSpeakers: [SpeakerNamingSimulationKnownSpeaker]
    public let meetings: [SpeakerNamingSimulationMeeting]
    public let minimumExactLabelAccuracy: Double

    public init(
        name: String,
        knownSpeakers: [SpeakerNamingSimulationKnownSpeaker] = [],
        meetings: [SpeakerNamingSimulationMeeting],
        minimumExactLabelAccuracy: Double = 1.0
    ) {
        self.name = name
        self.knownSpeakers = knownSpeakers
        self.meetings = meetings
        self.minimumExactLabelAccuracy = minimumExactLabelAccuracy
    }
}

@available(macOS 14.0, *)
public struct SpeakerNamingSimulationConfusionPair: Hashable, Sendable {
    public let expected: String
    public let actual: String
    public let count: Int
}

@available(macOS 14.0, *)
public struct SpeakerNamingSimulationMergeIndicator: Hashable, Sendable {
    public let actualLabel: String
    public let expectedLabels: [String]
    public let truthSpeakerIds: [String]
}

@available(macOS 14.0, *)
public struct SpeakerNamingSimulationSplitIndicator: Hashable, Sendable {
    public let truthSpeakerId: String
    public let actualLabels: [String]
}

@available(macOS 14.0, *)
public struct SpeakerNamingSimulationDuplicateIdentityIndicator: Hashable, Sendable {
    public let truthSpeakerId: String
    public let actualLabel: String
    public let speakerIds: [String]
    public let caseIds: [String]
}

@available(macOS 14.0, *)
public struct SpeakerNamingSimulationCaseReport: Sendable {
    public let id: String
    public let title: String
    public let transcriptURL: URL?
    public let evaluatedUtterances: Int
    public let exactMatches: Int
    public let confusionPairs: [SpeakerNamingSimulationConfusionPair]
    public let rollbackSucceeded: Bool?
    public let replacementSucceeded: Bool?
    public let notes: [String]

    public var exactLabelAccuracy: Double {
        guard evaluatedUtterances > 0 else { return 1.0 }
        return Double(exactMatches) / Double(evaluatedUtterances)
    }
}

@available(macOS 14.0, *)
public struct SpeakerNamingSimulationReport: Sendable {
    public let suiteName: String
    public let minimumExactLabelAccuracy: Double
    public let caseReports: [SpeakerNamingSimulationCaseReport]
    public let totalEvaluatedUtterances: Int
    public let exactMatches: Int
    public let confusionPairs: [SpeakerNamingSimulationConfusionPair]
    public let falseMergeIndicators: [SpeakerNamingSimulationMergeIndicator]
    public let falseSplitIndicators: [SpeakerNamingSimulationSplitIndicator]
    public let duplicateIdentityIndicators: [SpeakerNamingSimulationDuplicateIdentityIndicator]
    public let identityStabilityChecks: Int
    public let identityStabilitySuccesses: Int
    public let renamedPropagationChecks: Int
    public let renamedPropagationSuccesses: Int
    public let rollbackChecks: Int
    public let rollbackSuccesses: Int
    public let replacementChecks: Int
    public let replacementSuccesses: Int

    public var exactLabelAccuracy: Double {
        guard totalEvaluatedUtterances > 0 else { return 1.0 }
        return Double(exactMatches) / Double(totalEvaluatedUtterances)
    }

    public var renamedSpeakerPropagationSucceeded: Bool {
        renamedPropagationSuccesses == renamedPropagationChecks
    }

    public var identityStabilitySucceeded: Bool {
        identityStabilitySuccesses == identityStabilityChecks
    }

    public var rollbackSucceeded: Bool {
        rollbackSuccesses == rollbackChecks
    }

    public var replacementSucceeded: Bool {
        replacementSuccesses == replacementChecks
    }

    public var passed: Bool {
        exactLabelAccuracy >= minimumExactLabelAccuracy
            && (minimumExactLabelAccuracy < 1.0 || confusionPairs.isEmpty)
            && falseMergeIndicators.isEmpty
            && falseSplitIndicators.isEmpty
            && duplicateIdentityIndicators.isEmpty
            && identityStabilitySucceeded
            && renamedSpeakerPropagationSucceeded
            && rollbackSucceeded
            && replacementSucceeded
    }

    public var markdown: String {
        var lines: [String] = []
        lines.append("# Speaker Naming Simulation Report")
        lines.append("")
        lines.append("- Suite: \(suiteName)")
        lines.append("- Exact label accuracy: \(exactMatches)/\(totalEvaluatedUtterances) (\(Self.percent(exactLabelAccuracy)))")
        lines.append("- Minimum required accuracy: \(Self.percent(minimumExactLabelAccuracy))")
        lines.append("- Confusion pairs: \(confusionPairs.isEmpty ? "none" : "\(confusionPairs.count)")")
        lines.append("- False merge indicators: \(falseMergeIndicators.isEmpty ? "none" : "\(falseMergeIndicators.count)")")
        lines.append("- False split indicators: \(falseSplitIndicators.isEmpty ? "none" : "\(falseSplitIndicators.count)")")
        lines.append("- Duplicate identity indicators: \(duplicateIdentityIndicators.isEmpty ? "none" : "\(duplicateIdentityIndicators.count)")")
        lines.append("- Identity stability: \(identityStabilitySuccesses)/\(identityStabilityChecks)")
        lines.append("- Renamed propagation: \(renamedPropagationSuccesses)/\(renamedPropagationChecks)")
        lines.append("- Rollback: \(rollbackSuccesses)/\(rollbackChecks)")
        lines.append("- Saved-audio retranscription: \(replacementSuccesses)/\(replacementChecks)")
        lines.append("")
        lines.append("## Cases")
        for caseReport in caseReports {
            lines.append("- \(caseReport.id): \(caseReport.exactMatches)/\(caseReport.evaluatedUtterances) exact (\(Self.percent(caseReport.exactLabelAccuracy)))")
            for note in caseReport.notes {
                lines.append("  - \(note)")
            }
        }

        if !confusionPairs.isEmpty {
            lines.append("")
            lines.append("## Confusion Pairs")
            for pair in confusionPairs {
                lines.append("- expected \(pair.expected), got \(pair.actual): \(pair.count)")
            }
        }

        if !falseMergeIndicators.isEmpty {
            lines.append("")
            lines.append("## False Merge Indicators")
            for indicator in falseMergeIndicators {
                lines.append("- \(indicator.actualLabel): expected labels \(indicator.expectedLabels.joined(separator: ", ")) from truth speakers \(indicator.truthSpeakerIds.joined(separator: ", "))")
            }
        }

        if !falseSplitIndicators.isEmpty {
            lines.append("")
            lines.append("## False Split Indicators")
            for indicator in falseSplitIndicators {
                lines.append("- \(indicator.truthSpeakerId): actual labels \(indicator.actualLabels.joined(separator: ", "))")
            }
        }

        if !duplicateIdentityIndicators.isEmpty {
            lines.append("")
            lines.append("## Duplicate Identity Indicators")
            for indicator in duplicateIdentityIndicators {
                lines.append("- \(indicator.truthSpeakerId) / \(indicator.actualLabel): speaker ids \(indicator.speakerIds.joined(separator: ", ")) in cases \(indicator.caseIds.joined(separator: ", "))")
            }
        }

        return lines.joined(separator: "\n")
    }

    public func writeMarkdown(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

@available(macOS 14.0, *)
public final class SpeakerNamingSimulationRunner {
    public let workingDirectory: URL
    private let fileManager: FileManager

    public init(
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.workingDirectory = workingDirectory
        self.fileManager = fileManager
    }

    public func run(_ suite: SpeakerNamingSimulationSuite) throws -> SpeakerNamingSimulationReport {
        let paths = pathsUnderWorkingDirectory()
        try prepareDirectories(paths)
        let speakerDB = SpeakerDatabase(path: paths.speakerDB.path)
        var state = SimulationState(paths: paths, speakerDB: speakerDB)

        for knownSpeaker in suite.knownSpeakers {
            seed(knownSpeaker, into: speakerDB)
        }

        var caseReports: [SpeakerNamingSimulationCaseReport] = []
        var evaluatedByCaseId: [String: [EvaluatedUtterance]] = [:]
        var renamedChecks = 0
        var renamedSuccesses = 0
        var rollbackChecks = 0
        var rollbackSuccesses = 0
        var replacementChecks = 0
        var replacementSuccesses = 0

        for meeting in suite.meetings {
            let outcome = try runMeeting(meeting, state: &state)
            caseReports.append(outcome.caseReport)
            if let replacementTargetMeetingId = meeting.replacementTargetMeetingId,
               outcome.caseReport.replacementSucceeded == true {
                evaluatedByCaseId.removeValue(forKey: replacementTargetMeetingId)
            }
            evaluatedByCaseId[meeting.id] = outcome.evaluatedUtterances
            renamedChecks += outcome.renamedChecks
            renamedSuccesses += outcome.renamedSuccesses
            if let rollbackSucceeded = outcome.caseReport.rollbackSucceeded {
                rollbackChecks += 1
                if rollbackSucceeded { rollbackSuccesses += 1 }
            }
            if let replacementSucceeded = outcome.caseReport.replacementSucceeded {
                replacementChecks += 1
                if replacementSucceeded { replacementSuccesses += 1 }
            }
        }

        let evaluated = suite.meetings.flatMap { evaluatedByCaseId[$0.id] ?? [] }
        let confusionPairs = aggregateConfusionPairs(evaluated)
        let falseMergeIndicators = falseMergeIndicators(evaluated)
        let falseSplitIndicators = falseSplitIndicators(evaluated)
        let identityStability = identityStability(evaluated)

        return SpeakerNamingSimulationReport(
            suiteName: suite.name,
            minimumExactLabelAccuracy: suite.minimumExactLabelAccuracy,
            caseReports: caseReports,
            totalEvaluatedUtterances: evaluated.count,
            exactMatches: evaluated.filter(\.isExactMatch).count,
            confusionPairs: confusionPairs,
            falseMergeIndicators: falseMergeIndicators,
            falseSplitIndicators: falseSplitIndicators,
            duplicateIdentityIndicators: identityStability.indicators,
            identityStabilityChecks: identityStability.checks,
            identityStabilitySuccesses: identityStability.successes,
            renamedPropagationChecks: renamedChecks,
            renamedPropagationSuccesses: renamedSuccesses,
            rollbackChecks: rollbackChecks,
            rollbackSuccesses: rollbackSuccesses,
            replacementChecks: replacementChecks,
            replacementSuccesses: replacementSuccesses
        )
    }

    private var runDirectory: URL {
        workingDirectory.appendingPathComponent("speaker-naming-simulation-run", isDirectory: true)
    }

    private func pathsUnderWorkingDirectory() -> CoreStoragePaths {
        let root = runDirectory
        return CoreStoragePaths(
            transcripts: root.appendingPathComponent("transcripts", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("state/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("audio", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
    }

    private func prepareDirectories(_ paths: CoreStoragePaths) throws {
        try? fileManager.removeItem(at: runDirectory)
        try fileManager.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.speakerDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.speakerClips, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.logs, withIntermediateDirectories: true)
    }

    private func seed(_ knownSpeaker: SpeakerNamingSimulationKnownSpeaker, into speakerDB: SpeakerDatabase) {
        let profile = speakerDB.addOrUpdateSpeaker(embedding: knownSpeaker.embedding, existingId: nil)
        if knownSpeaker.callCount > 1 {
            for _ in 1..<knownSpeaker.callCount {
                _ = speakerDB.addOrUpdateSpeaker(embedding: knownSpeaker.embedding, existingId: profile.id)
            }
        }
        speakerDB.setDisplayName(id: profile.id, name: knownSpeaker.displayName, source: NameSource.userManual)
    }

    private func runMeeting(
        _ meeting: SpeakerNamingSimulationMeeting,
        state: inout SimulationState
    ) throws -> MeetingOutcome {
        let existingProfiles = state.speakerDB.allSpeakers()
        var processed = processSegments(
            meeting.segments,
            existingProfiles: existingProfiles,
            pairwiseMergeThreshold: meeting.pairwiseMergeThreshold
        )
        let classification = classify(&processed, existingProfiles: existingProfiles, speakerDB: state.speakerDB)
        let result = transcriptionResult(from: processed, classification: classification)
        let transcriptId = state.records[meeting.replacementTargetMeetingId ?? ""]?.transcriptId ?? UUID()
        let targetURL = state.records[meeting.replacementTargetMeetingId ?? ""]?.url
        let replacementOriginalData = targetURL.flatMap { try? Data(contentsOf: $0) }
        let transcriptURL = try saveTranscript(
            result: result,
            meeting: meeting,
            transcriptId: transcriptId,
            classification: classification,
            targetURL: targetURL,
            directory: state.paths.transcripts
        )

        var notes: [String] = []
        var rollbackSucceeded: Bool?
        var replacementSucceeded: Bool?

        if meeting.actions.containsCancelBeforeNaming {
            rollbackSucceeded = rollbackTranscript(
                url: transcriptURL,
                originalData: replacementOriginalData
            )
            notes.append(rollbackSucceeded == true ? "rollback restored transcript state" : "rollback failed")

            let record = MeetingRecord(
                id: meeting.id,
                url: targetURL ?? transcriptURL,
                transcriptId: transcriptId,
                segments: targetURL == nil ? [] : (state.records[meeting.replacementTargetMeetingId ?? ""]?.segments ?? []),
                speakerIdsByKey: targetURL == nil ? [:] : (state.records[meeting.replacementTargetMeetingId ?? ""]?.speakerIdsByKey ?? [:])
            )
            state.records[meeting.id] = record

            return MeetingOutcome(
                caseReport: SpeakerNamingSimulationCaseReport(
                    id: meeting.id,
                    title: meeting.title,
                    transcriptURL: fileManager.fileExists(atPath: record.url.path) ? record.url : nil,
                    evaluatedUtterances: 0,
                    exactMatches: 0,
                    confusionPairs: [],
                    rollbackSucceeded: rollbackSucceeded,
                    replacementSucceeded: nil,
                    notes: notes
                ),
                evaluatedUtterances: [],
                renamedChecks: 0,
                renamedSuccesses: 0
            )
        }

        let updates = buildUpdates(
            for: meeting.actions,
            classification: classification,
            speakerDB: state.speakerDB
        )
        let deferredReviewPlan = updates.isEmpty && meeting.actions.containsDeferAll
            ? planDeferredReview(classification: classification)
            : nil
        try apply(
            actions: meeting.actions,
            updates: updates,
            deferredReviewPlan: deferredReviewPlan,
            transcriptURL: transcriptURL,
            result: result,
            classification: classification,
            speakerDB: state.speakerDB
        )

        let speakerIdsByKey = resolvedSpeakerIdsByKey(
            classification: classification,
            updates: updates,
            redirectedSpeakerIdsByKey: deferredReviewPlan?.redirectedSpeakerIdsByKey ?? [:]
        )
        let record = MeetingRecord(
            id: meeting.id,
            url: transcriptURL,
            transcriptId: transcriptId,
            segments: processed,
            speakerIdsByKey: speakerIdsByKey
        )
        state.records[meeting.id] = record

        var renamedChecks = 0
        var renamedSuccesses = 0
        for postAction in meeting.postActions {
            let postOutcome = try apply(postAction: postAction, meetingRecord: record, state: &state)
            renamedChecks += postOutcome.checks
            renamedSuccesses += postOutcome.successes
            notes.append(contentsOf: postOutcome.notes)
        }

        if let replacementTargetMeetingId = meeting.replacementTargetMeetingId {
            replacementSucceeded = transcriptURL == state.records[replacementTargetMeetingId]?.url
            if replacementSucceeded == true {
                state.records[replacementTargetMeetingId] = record
                notes.append("saved-audio retranscription replaced \(replacementTargetMeetingId)")
            } else {
                notes.append("saved-audio retranscription did not reuse target transcript URL")
            }
        }

        let evaluated = try evaluate(record: state.records[meeting.id] ?? record)
        let caseConfusions = aggregateConfusionPairs(evaluated)
        let exactMatches = evaluated.filter(\.isExactMatch).count

        return MeetingOutcome(
            caseReport: SpeakerNamingSimulationCaseReport(
                id: meeting.id,
                title: meeting.title,
                transcriptURL: transcriptURL,
                evaluatedUtterances: evaluated.count,
                exactMatches: exactMatches,
                confusionPairs: caseConfusions,
                rollbackSucceeded: rollbackSucceeded,
                replacementSucceeded: replacementSucceeded,
                notes: notes
            ),
            evaluatedUtterances: evaluated,
            renamedChecks: renamedChecks,
            renamedSuccesses: renamedSuccesses
        )
    }

    private func processSegments(
        _ segments: [SpeakerNamingSimulationSegment],
        existingProfiles: [SpeakerProfile],
        pairwiseMergeThreshold: Float?
    ) -> [ProcessedSegment] {
        var processed: [ProcessedSegment] = []
        for channel in [UtteranceChannel.mic, .system] {
            let channelSegments = segments.filter { $0.channel == channel }
            guard !channelSegments.isEmpty else { continue }
            let raw = channelSegments.map {
                SpeakerSegment(
                    speakerId: $0.diarizerSpeakerId,
                    startTime: $0.start,
                    endTime: $0.start + $0.duration,
                    embedding: $0.embedding,
                    qualityScore: $0.qualityScore
                )
            }
            let postProcessed = EmbeddingClusterer.postProcess(
                segments: raw,
                existingProfiles: existingProfiles,
                pairwiseMergeThreshold: pairwiseMergeThreshold
            )
            for (fixture, segment) in zip(channelSegments, postProcessed) {
                processed.append(ProcessedSegment(fixture: fixture, effectiveSpeakerId: segment.speakerId))
            }
        }
        return processed.sorted { $0.fixture.start < $1.fixture.start }
    }

    private func classify(
        _ segments: inout [ProcessedSegment],
        existingProfiles: [SpeakerProfile],
        speakerDB: SpeakerDatabase
    ) -> Classification {
        var contexts: [String: ChannelSpeakerContext] = [:]
        let grouped = Dictionary(grouping: segments) { segment in
            segment.fixture.channel.speakerKey(diarizerSpeakerId: String(segment.effectiveSpeakerId))
        }

        for key in grouped.keys.sorted() {
            guard let group = grouped[key],
                  let first = group.first else { continue }
            let usableEmbeddings = group.compactMap { processed -> [Float]? in
                guard processed.fixture.includeInTranscript,
                      processed.fixture.duration >= 1.0,
                      processed.fixture.qualityScore >= 0.3,
                      let embedding = processed.fixture.embedding,
                      !embedding.isEmpty else {
                    return nil
                }
                return embedding
            }
            let embeddings = usableEmbeddings.isEmpty
                ? bestVisibleEmbedding(in: group).map { [$0] } ?? []
                : usableEmbeddings
            guard !embeddings.isEmpty else { continue }

            let meanEmbedding = Transcription.computeMeanEmbedding(embeddings)
            let threshold: Double = switch embeddings.count {
            case 1: 0.85
            case 2...3: 0.78
            default: 0.70
            }

            if let match = Transcription.matchAgainstProfiles(
                meanEmbedding,
                profiles: existingProfiles,
                threshold: threshold
            ) {
                _ = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding, existingId: match.profileId)
                let snapshot = existingProfiles.first { $0.id == match.profileId }
                contexts[key] = ChannelSpeakerContext(
                    persistentSpeakerId: match.profileId,
                    sessionEmbedding: meanEmbedding,
                    matchedProfileSnapshot: snapshot,
                    matchSimilarity: match.similarity
                )
            } else {
                let profile = speakerDB.addOrUpdateSpeaker(embedding: meanEmbedding, existingId: nil)
                contexts[key] = ChannelSpeakerContext(
                    persistentSpeakerId: profile.id,
                    sessionEmbedding: meanEmbedding,
                    matchedProfileSnapshot: nil,
                    matchSimilarity: nil
                )
            }

            _ = first
        }

        let speakerIdRemap = sameProfileSpeakerIdRemap(
            contexts: contexts,
            groupedSegments: grouped
        )
        if !speakerIdRemap.isEmpty {
            segments = segments.map { segment in
                let key = segment.fixture.channel.speakerKey(diarizerSpeakerId: String(segment.effectiveSpeakerId))
                guard let remappedId = speakerIdRemap[key] else { return segment }
                return ProcessedSegment(fixture: segment.fixture, effectiveSpeakerId: remappedId)
            }

            for key in speakerIdRemap.keys {
                contexts.removeValue(forKey: key)
            }
        }

        return Classification(contexts: contexts)
    }

    private func bestVisibleEmbedding(in group: [ProcessedSegment]) -> [Float]? {
        group
            .filter { $0.fixture.includeInTranscript }
            .compactMap { segment -> (quality: Float, duration: TimeInterval, embedding: [Float])? in
                guard let embedding = segment.fixture.embedding, !embedding.isEmpty else { return nil }
                return (segment.fixture.qualityScore, segment.fixture.duration, embedding)
            }
            .max {
                if $0.quality != $1.quality { return $0.quality < $1.quality }
                return $0.duration < $1.duration
            }?
            .embedding
    }

    private func sameProfileSpeakerIdRemap(
        contexts: [String: ChannelSpeakerContext],
        groupedSegments: [String: [ProcessedSegment]]
    ) -> [String: Int] {
        let matchedKeys = contexts.keys.filter { contexts[$0]?.matchedProfileSnapshot != nil }
        let groupedByProfileAndChannel = Dictionary(grouping: matchedKeys) { key -> String in
            guard let context = contexts[key],
                  let parsed = parseSpeakerKey(key) else { return key }
            return "\(parsed.channel.rawValue)_\(context.persistentSpeakerId.uuidString)"
        }

        var remap: [String: Int] = [:]
        for keys in groupedByProfileAndChannel.values where keys.count > 1 {
            let sortedKeys = keys.sorted { lhs, rhs in
                let lhsCount = groupedSegments[lhs]?.count ?? 0
                let rhsCount = groupedSegments[rhs]?.count ?? 0
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                return lhs < rhs
            }
            guard let canonicalKey = sortedKeys.first,
                  let canonical = parseSpeakerKey(canonicalKey) else { continue }
            for key in sortedKeys.dropFirst() {
                remap[key] = canonical.diarizerSpeakerId
            }
        }
        return remap
    }

    private func transcriptionResult(
        from segments: [ProcessedSegment],
        classification: Classification
    ) -> TranscriptionResult {
        let utterances = segments.compactMap { segment -> TranscriptionUtterance? in
            guard segment.fixture.includeInTranscript else { return nil }
            let key = segment.fixture.channel.speakerKey(diarizerSpeakerId: String(segment.effectiveSpeakerId))
            let context = classification.contexts[key]
            return TranscriptionUtterance(
                start: segment.fixture.start,
                end: segment.fixture.start + segment.fixture.duration,
                channel: segment.fixture.channel == .mic ? 0 : 1,
                speakerId: segment.effectiveSpeakerId,
                persistentSpeakerId: context?.persistentSpeakerId,
                matchSimilarity: context?.matchSimilarity,
                transcript: segment.fixture.text
            )
        }

        let duration = utterances.map(\.end).max() ?? 0
        return TranscriptionResult(
            micUtterances: utterances.filter { $0.channel == 0 },
            systemUtterances: utterances.filter { $0.channel == 1 },
            systemSpeakerContexts: classification.contexts.filter { $0.key.hasPrefix("system_") },
            micSpeakerContexts: classification.contexts.filter { $0.key.hasPrefix("mic_") },
            duration: duration,
            processingTime: 0.1
        )
    }

    private func saveTranscript(
        result: TranscriptionResult,
        meeting: SpeakerNamingSimulationMeeting,
        transcriptId: UUID,
        classification: Classification,
        targetURL: URL?,
        directory: URL
    ) throws -> URL {
        var speakerMappings: [String: SpeakerMapping] = [:]
        var speakerSources: [String: String] = [:]
        var speakerDbIds: [String: UUID] = [:]

        let utterances = result.allUtterances
        let keys = Set(utterances.map { utterance in
            let channel: UtteranceChannel = utterance.channel == 0 ? .mic : .system
            return channel.speakerKey(diarizerSpeakerId: String(utterance.speakerId))
        })

        for key in keys {
            guard let context = classification.contexts[key] else { continue }
            speakerDbIds[key] = context.persistentSpeakerId
            let speakerId = key.split(separator: "_", maxSplits: 1).last.map(String.init) ?? key

            if let snapshot = context.matchedProfileSnapshot,
               let similarity = context.matchSimilarity {
                let canAutoAccept = SpeakerNamingPolicy.shouldAutoAccept(
                    profile: snapshot,
                    similarity: similarity
                )
                speakerMappings[key] = SpeakerNamingPolicy.initialMapping(
                    speakerId: speakerId,
                    profile: snapshot,
                    similarity: similarity
                )
                speakerSources[key] = canAutoAccept ? "db" : "db_pending"
            } else {
                speakerMappings[key] = SpeakerMapping(speakerId: speakerId)
                speakerSources[key] = "db_pending"
            }
        }

        guard let savedURL = TranscriptSaver.saveTranscript(
            result,
            transcriptId: transcriptId,
            speakerMappings: speakerMappings,
            speakerSources: speakerSources,
            speakerDbIds: speakerDbIds,
            directory: directory,
            meetingTitle: meeting.title,
            healthInfo: nil,
            notifier: nil,
            speakerStore: nil,
            statsStore: NoopStatsStore(),
            recordingDate: meeting.recordingDate,
            targetURL: targetURL,
            transcriptionEngine: .parakeetLocal,
            formatOptions: .default
        ) else {
            throw SimulationError.saveFailed(meeting.id)
        }
        return savedURL
    }

    private func buildUpdates(
        for actions: [SpeakerNamingSimulationAction],
        classification: Classification,
        speakerDB: SpeakerDatabase
    ) -> [SpeakerNameUpdate] {
        var updates: [SpeakerNameUpdate] = []
        var manualNameTargets: [String: (id: UUID, displayName: String)] = [:]

        for action in actions {
            switch action {
            case .name(let channel, let diarizerSpeakerId, let name):
                guard let context = classification.context(channel: channel, diarizerSpeakerId: diarizerSpeakerId) else { continue }
                let resolved: UUID?
                let resolvedName: String
                if let manualTarget = manualNameTargets[normalizeName(name)] {
                    resolved = manualTarget.id
                    resolvedName = manualTarget.displayName
                } else {
                    resolved = exactNamedTarget(named: name, excluding: context.persistentSpeakerId, speakerDB: speakerDB)?.id
                    resolvedName = name
                    manualNameTargets[normalizeName(name)] = (resolved ?? context.persistentSpeakerId, name)
                }
                updates.append(SpeakerNameUpdate(
                    persistentSpeakerId: context.persistentSpeakerId,
                    diarizerSpeakerId: String(diarizerSpeakerId),
                    channel: channel,
                    newName: resolvedName,
                    action: .named,
                    resolvedPersistentSpeakerId: resolved
                ))

            case .confirm(let channel, let diarizerSpeakerId, let name):
                guard let context = classification.context(channel: channel, diarizerSpeakerId: diarizerSpeakerId) else { continue }
                updates.append(SpeakerNameUpdate(
                    persistentSpeakerId: context.persistentSpeakerId,
                    diarizerSpeakerId: String(diarizerSpeakerId),
                    channel: channel,
                    newName: name,
                    previousName: context.matchedProfileSnapshot?.displayName,
                    action: .confirmed,
                    resolvedPersistentSpeakerId: nil
                ))

            case .correct(let channel, let diarizerSpeakerId, let previousName, let newName):
                guard let context = classification.context(channel: channel, diarizerSpeakerId: diarizerSpeakerId) else { continue }
                let resolved: UUID?
                let resolvedName: String
                if let manualTarget = manualNameTargets[normalizeName(newName)] {
                    resolved = manualTarget.id
                    resolvedName = manualTarget.displayName
                } else {
                    resolved = correctedTargetId(
                        named: newName,
                        context: context,
                        speakerDB: speakerDB
                    )
                    resolvedName = newName
                    manualNameTargets[normalizeName(newName)] = (resolved ?? context.persistentSpeakerId, newName)
                }
                updates.append(SpeakerNameUpdate(
                    persistentSpeakerId: context.persistentSpeakerId,
                    diarizerSpeakerId: String(diarizerSpeakerId),
                    channel: channel,
                    newName: resolvedName,
                    previousName: previousName ?? context.matchedProfileSnapshot?.displayName,
                    action: .corrected,
                    resolvedPersistentSpeakerId: resolved
                ))

            case .merge(let channel, let diarizerSpeakerId, let targetName):
                guard let context = classification.context(channel: channel, diarizerSpeakerId: diarizerSpeakerId),
                      let target = exactNamedTarget(named: targetName, excluding: context.persistentSpeakerId, speakerDB: speakerDB) else { continue }
                updates.append(SpeakerNameUpdate(
                    persistentSpeakerId: context.persistentSpeakerId,
                    diarizerSpeakerId: String(diarizerSpeakerId),
                    channel: channel,
                    newName: target.displayName ?? targetName,
                    action: .merged(targetProfileId: target.id),
                    resolvedPersistentSpeakerId: target.id
                ))

            case .discard(let channel, let diarizerSpeakerId):
                guard let context = classification.context(channel: channel, diarizerSpeakerId: diarizerSpeakerId) else { continue }
                updates.append(SpeakerNameUpdate(
                    persistentSpeakerId: context.persistentSpeakerId,
                    diarizerSpeakerId: String(diarizerSpeakerId),
                    channel: channel,
                    newName: "Speaker \(diarizerSpeakerId)",
                    previousName: context.matchedProfileSnapshot?.displayName,
                    action: .discardedFromDatabase
                ))

            case .collapseMicToYou:
                let micContexts = classification.contexts.compactMap { key, context -> (Int, ChannelSpeakerContext)? in
                    guard key.hasPrefix("mic_"),
                          let id = Int(key.dropFirst("mic_".count)) else { return nil }
                    return (id, context)
                }
                for (diarizerSpeakerId, context) in micContexts {
                    updates.append(SpeakerNameUpdate(
                        persistentSpeakerId: context.persistentSpeakerId,
                        diarizerSpeakerId: String(diarizerSpeakerId),
                        channel: .mic,
                        newName: "You",
                        previousName: context.matchedProfileSnapshot?.displayName,
                        action: .collapsedToMe
                    ))
                }

            case .deferAll, .cancelBeforeNaming:
                continue
            }
        }

        return updates
    }

    private func apply(
        actions: [SpeakerNamingSimulationAction],
        updates: [SpeakerNameUpdate],
        deferredReviewPlan: DeferredReviewPlan?,
        transcriptURL: URL,
        result: TranscriptionResult,
        classification: Classification,
        speakerDB: SpeakerDatabase
    ) throws {
        if let deferredReviewPlan {
            guard TranscriptSaver.markSpeakerReviewDeferred(
                transcriptURL: transcriptURL,
                entries: deferredReviewPlan.entries,
                redirectedSpeakerIdsByKey: deferredReviewPlan.redirectedSpeakerIdsByKey
            ) else {
                throw SimulationError.updateFailed(transcriptURL.lastPathComponent)
            }
            applyDeferredReviewPlan(deferredReviewPlan, speakerDB: speakerDB)
            return
        }

        let collapsed = updates.filter {
            if case .collapsedToMe = $0.action { return true }
            return false
        }
        let discarded = updates.filter {
            if case .discardedFromDatabase = $0.action { return true }
            return false
        }
        let regular = updates.filter { update in
            switch update.action {
            case .collapsedToMe, .discardedFromDatabase:
                return false
            case .named, .confirmed, .corrected, .merged:
                return true
            }
        }

        if !regular.isEmpty {
            guard TranscriptSaver.updateSpeakerNames(
                transcriptURL: transcriptURL,
                updates: regular,
                transcriptionResult: result
            ) else {
                throw SimulationError.updateFailed(transcriptURL.lastPathComponent)
            }
            applyDatabaseUpdates(regular, classification: classification, speakerDB: speakerDB)
        }

        if !collapsed.isEmpty {
            guard TranscriptSaver.collapseMicSpeakersToYou(
                transcriptURL: transcriptURL,
                collapsedUpdates: collapsed
            ) else {
                throw SimulationError.updateFailed(transcriptURL.lastPathComponent)
            }
            for update in collapsed {
                let context = classification.context(
                    channel: update.channel,
                    diarizerSpeakerId: Int(update.diarizerSpeakerId) ?? -1
                )
                if let snapshot = context?.matchedProfileSnapshot {
                    speakerDB.restoreProfile(snapshot)
                    speakerDB.incrementDisputeCount(id: snapshot.id)
                } else {
                    speakerDB.deleteSpeaker(id: update.persistentSpeakerId)
                }
            }
        }

        if !discarded.isEmpty {
            guard TranscriptSaver.discardSpeakerDatabaseLinks(
                transcriptURL: transcriptURL,
                discardedUpdates: discarded
            ) else {
                throw SimulationError.updateFailed(transcriptURL.lastPathComponent)
            }
            for update in discarded {
                let context = classification.context(
                    channel: update.channel,
                    diarizerSpeakerId: Int(update.diarizerSpeakerId) ?? -1
                )
                if let snapshot = context?.matchedProfileSnapshot {
                    speakerDB.restoreProfile(snapshot)
                    speakerDB.incrementDisputeCount(id: snapshot.id)
                } else if context?.matchSimilarity == nil {
                    speakerDB.deleteSpeaker(id: update.persistentSpeakerId)
                }
            }
        }
    }

    private func resolvedSpeakerIdsByKey(
        classification: Classification,
        updates: [SpeakerNameUpdate],
        redirectedSpeakerIdsByKey: [String: UUID]
    ) -> [String: UUID] {
        var idsByKey = classification.contexts.mapValues(\.persistentSpeakerId)
        for (key, redirectedId) in redirectedSpeakerIdsByKey {
            idsByKey[key] = redirectedId
        }

        for update in updates {
            let key = update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)
            switch update.action {
            case .collapsedToMe, .discardedFromDatabase:
                idsByKey.removeValue(forKey: key)
            case .merged(let targetProfileId):
                idsByKey[key] = targetProfileId
            case .named, .confirmed, .corrected:
                idsByKey[key] = update.resolvedPersistentSpeakerId ?? update.persistentSpeakerId
            }
        }

        return idsByKey
    }

    private func planDeferredReview(classification: Classification) -> DeferredReviewPlan {
        var entries: [SpeakerNamingEntry] = []
        var redirectedSpeakerIdsByKey: [String: UUID] = [:]
        var redirectedProfiles: [DeferredReviewProfile] = []

        for key in classification.contexts.keys.sorted() {
            guard let context = classification.contexts[key],
                  let parsed = parseSpeakerKey(key) else { continue }
            let diarizerSpeakerId = String(parsed.diarizerSpeakerId)
            entries.append(SpeakerNamingEntry(
                id: context.persistentSpeakerId,
                suggestedProfileId: context.matchedProfileSnapshot?.id,
                diarizerSpeakerId: diarizerSpeakerId,
                channel: parsed.channel,
                clipURL: runDirectory
                    .appendingPathComponent("state/speaker_clips", isDirectory: true)
                    .appendingPathComponent("\(key).wav"),
                sampleText: "",
                currentName: context.matchedProfileSnapshot?.displayName,
                matchSimilarity: context.matchSimilarity,
                callCount: context.matchedProfileSnapshot?.callCount ?? 1,
                needsNaming: context.matchedProfileSnapshot == nil,
                needsConfirmation: context.matchedProfileSnapshot != nil,
                sessionEmbedding: context.sessionEmbedding,
                matchedProfileSnapshot: context.matchedProfileSnapshot
            ))

            guard let matchedProfile = context.matchedProfileSnapshot,
                  let embedding = context.sessionEmbedding else { continue }
            let deferredProfileId = UUID()
            redirectedSpeakerIdsByKey[key] = deferredProfileId
            redirectedProfiles.append(DeferredReviewProfile(
                matchedProfile: matchedProfile,
                deferredProfileId: deferredProfileId,
                embedding: embedding
            ))
        }

        return DeferredReviewPlan(
            entries: entries,
            redirectedSpeakerIdsByKey: redirectedSpeakerIdsByKey,
            redirectedProfiles: redirectedProfiles
        )
    }

    private func applyDeferredReviewPlan(_ plan: DeferredReviewPlan, speakerDB: SpeakerDatabase) {
        for profile in plan.redirectedProfiles {
            speakerDB.restoreProfile(profile.matchedProfile)
            _ = speakerDB.addOrUpdateSpeaker(
                embedding: profile.embedding,
                existingId: profile.deferredProfileId
            )
        }
    }

    private func applyDatabaseUpdates(
        _ updates: [SpeakerNameUpdate],
        classification: Classification,
        speakerDB: SpeakerDatabase
    ) {
        for update in updates {
            let resolvedId = update.resolvedPersistentSpeakerId ?? update.persistentSpeakerId
            let context = classification.context(
                channel: update.channel,
                diarizerSpeakerId: Int(update.diarizerSpeakerId) ?? -1
            )

            switch update.action {
            case .named:
                if resolvedId != update.persistentSpeakerId {
                    speakerDB.mergeProfiles(sourceId: update.persistentSpeakerId, into: resolvedId)
                }
                speakerDB.setDisplayName(id: resolvedId, name: update.newName, source: NameSource.userManual)
                speakerDB.resetDisputeCount(id: resolvedId)

            case .confirmed:
                if resolvedId != update.persistentSpeakerId {
                    speakerDB.mergeProfiles(sourceId: update.persistentSpeakerId, into: resolvedId)
                }
                speakerDB.setDisplayName(id: resolvedId, name: update.newName, source: NameSource.userManual)
                speakerDB.resetDisputeCount(id: resolvedId)

            case .corrected:
                if let snapshot = context?.matchedProfileSnapshot {
                    speakerDB.restoreProfile(snapshot)
                    speakerDB.incrementDisputeCount(id: snapshot.id)
                }
                if let embedding = context?.sessionEmbedding {
                    _ = speakerDB.addOrUpdateSpeaker(embedding: embedding, existingId: resolvedId)
                }
                speakerDB.setDisplayName(id: resolvedId, name: update.newName, source: NameSource.userManual)
                speakerDB.resetDisputeCount(id: resolvedId)

            case .merged(let targetProfileId):
                speakerDB.mergeProfiles(sourceId: update.persistentSpeakerId, into: targetProfileId)
                speakerDB.resetDisputeCount(id: targetProfileId)

            case .collapsedToMe, .discardedFromDatabase:
                break
            }
        }
    }

    private func apply(
        postAction: SpeakerNamingSimulationPostAction,
        meetingRecord: MeetingRecord,
        state: inout SimulationState
    ) throws -> PostActionOutcome {
        switch postAction {
        case .nameDeferred(let channel, let diarizerSpeakerId, let name):
            let key = channel.speakerKey(diarizerSpeakerId: String(diarizerSpeakerId))
            guard let speakerId = meetingRecord.speakerIdsByKey[key] else {
                return PostActionOutcome(checks: 1, successes: 0, notes: ["missing deferred speaker for \(key)"])
            }

            let records = state.records.values.filter { record in
                record.speakerIdsByKey.values.contains(speakerId)
            }
            var checks = 0
            var successes = 0
            for record in records {
                for (recordKey, dbId) in record.speakerIdsByKey where dbId == speakerId {
                    guard let target = parseSpeakerKey(recordKey) else { continue }
                    checks += 1
                    if TranscriptSaver.updateDeferredSpeakerName(
                        transcriptURL: record.url,
                        dbId: speakerId,
                        diarizerSpeakerId: String(target.diarizerSpeakerId),
                        channel: target.channel,
                        newName: name
                    ) {
                        successes += 1
                    }
                }
            }
            state.speakerDB.setDisplayName(id: speakerId, name: name, source: NameSource.userManual)
            state.speakerDB.resetDisputeCount(id: speakerId)
            return PostActionOutcome(
                checks: max(1, checks),
                successes: successes,
                notes: ["deferred speaker named \(name) across \(records.count) transcript(s)"]
            )

        case .renameProfile(let channel, let diarizerSpeakerId, let name):
            let key = channel.speakerKey(diarizerSpeakerId: String(diarizerSpeakerId))
            guard let speakerId = meetingRecord.speakerIdsByKey[key] else {
                return PostActionOutcome(checks: 1, successes: 0, notes: ["missing speaker for rename \(key)"])
            }
            state.speakerDB.setDisplayName(id: speakerId, name: name, source: NameSource.userManual)
            state.speakerDB.resetDisputeCount(id: speakerId)
            TranscriptSaver.retroactivelyUpdateSpeaker(
                dbId: speakerId,
                newName: name,
                in: state.paths.transcripts
            )
            let rows = transcriptRows(for: speakerId, in: state.paths.transcripts)
            let successes = rows.filter { $0.name == name }.count
            return PostActionOutcome(
                checks: max(1, rows.count),
                successes: successes,
                notes: ["renamed profile to \(name)"]
            )

        case .mergeProfile(let channel, let diarizerSpeakerId, let targetName):
            let key = channel.speakerKey(diarizerSpeakerId: String(diarizerSpeakerId))
            guard let sourceId = meetingRecord.speakerIdsByKey[key],
                  let target = exactNamedTarget(named: targetName, excluding: sourceId, speakerDB: state.speakerDB) else {
                return PostActionOutcome(checks: 1, successes: 0, notes: ["missing merge target \(targetName)"])
            }
            state.speakerDB.mergeProfiles(sourceId: sourceId, into: target.id)
            TranscriptSaver.retroactivelyMergeSpeaker(
                sourceDbId: sourceId,
                targetDbId: target.id,
                targetName: target.displayName ?? targetName,
                in: state.paths.transcripts
            )
            return PostActionOutcome(
                checks: 1,
                successes: mergeRowsResolved(
                    sourceId: sourceId,
                    targetId: target.id,
                    targetName: target.displayName ?? targetName,
                    in: state.paths.transcripts
                ) ? 1 : 0,
                notes: ["merged profile into \(targetName)"]
            )
        }
    }

    private func evaluate(record: MeetingRecord) throws -> [EvaluatedUtterance] {
        guard fileManager.fileExists(atPath: record.url.path) else { return [] }
        let markdown = try String(contentsOf: record.url, encoding: .utf8)
        let transcriptLines = transcriptLines(in: markdown)
        var usedLineIndices = Set<Int>()
        return record.segments.compactMap { segment in
            guard segment.fixture.includeInTranscript else { return nil }
            let actual = actualLabel(
                for: segment.fixture,
                in: transcriptLines,
                usedLineIndices: &usedLineIndices
            )
            return EvaluatedUtterance(
                caseId: record.id,
                truthSpeakerId: segment.fixture.truthSpeakerId,
                expected: segment.fixture.expectedDisplayName,
                actual: actual ?? "(missing)",
                speakerId: record.speakerIdsByKey[
                    segment.fixture.channel.speakerKey(diarizerSpeakerId: String(segment.effectiveSpeakerId))
                ]
            )
        }
    }

    private func actualLabel(
        for segment: SpeakerNamingSimulationSegment,
        in lines: [ParsedTranscriptLine],
        usedLineIndices: inout Set<Int>
    ) -> String? {
        let expectedTimestamp = formatTranscriptTimestamp(segment.start)
        let expectedSource = segment.channel == .mic ? "Mic" : "System"

        for (index, line) in lines.enumerated() {
            guard !usedLineIndices.contains(index),
                  line.timestamp == expectedTimestamp,
                  line.source == expectedSource,
                  line.text == segment.text else {
                continue
            }
            usedLineIndices.insert(index)
            return line.label
        }
        return nil
    }

    private func transcriptLines(in markdown: String) -> [ParsedTranscriptLine] {
        markdown.components(separatedBy: .newlines).compactMap(parseTranscriptLine)
    }

    private func parseTranscriptLine(_ line: String) -> ParsedTranscriptLine? {
        guard line.first == "[" else { return nil }
        var search = line[...]
        guard let firstClose = search.firstIndex(of: "]") else { return nil }
        let timestamp = String(search[line.index(after: line.startIndex)..<firstClose])
        search = search[line.index(after: firstClose)...]
        guard let open = search.firstIndex(of: "["),
              let close = search[open...].firstIndex(of: "]") else {
            return nil
        }
        let raw = String(search[line.index(after: open)..<close])
        guard let slash = raw.firstIndex(of: "/") else { return nil }
        let textStart = line.index(after: close)
        let text = line[textStart...].trimmingCharacters(in: .whitespaces)
        return ParsedTranscriptLine(
            timestamp: timestamp,
            source: String(raw[..<slash]),
            label: normalizeDisplayLabel(String(raw[raw.index(after: slash)...])),
            text: text
        )
    }

    private func formatTranscriptTimestamp(_ start: TimeInterval) -> String {
        let startMinutes = Int(start) / 60
        let startSeconds = Int(start) % 60
        return String(format: "%02d:%02d", startMinutes, startSeconds)
    }

    private func normalizeDisplayLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rollbackTranscript(url: URL, originalData: Data?) -> Bool {
        do {
            if let originalData {
                try originalData.write(to: url, options: .atomic)
                return true
            }
            try? fileManager.removeItem(at: url)
            return !fileManager.fileExists(atPath: url.path)
        } catch {
            return false
        }
    }

    private func aggregateConfusionPairs(_ evaluated: [EvaluatedUtterance]) -> [SpeakerNamingSimulationConfusionPair] {
        let grouped = Dictionary(grouping: evaluated.filter { !$0.isExactMatch }) {
            "\($0.expected)\u{1F}\($0.actual)"
        }
        return grouped.map { _, values in
            SpeakerNamingSimulationConfusionPair(
                expected: values[0].expected,
                actual: values[0].actual,
                count: values.count
            )
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.expected != $1.expected { return $0.expected < $1.expected }
            return $0.actual < $1.actual
        }
    }

    private func falseMergeIndicators(_ evaluated: [EvaluatedUtterance]) -> [SpeakerNamingSimulationMergeIndicator] {
        let grouped = Dictionary(grouping: evaluated) { $0.actual }
        return grouped.compactMap { actual, values in
            let expectedLabels = Set(values.map(\.expected))
            let truthSpeakerIds = Set(values.map(\.truthSpeakerId))
            guard expectedLabels.count > 1, truthSpeakerIds.count > 1 else { return nil }
            return SpeakerNamingSimulationMergeIndicator(
                actualLabel: actual,
                expectedLabels: expectedLabels.sorted(),
                truthSpeakerIds: truthSpeakerIds.sorted()
            )
        }
        .sorted { $0.actualLabel < $1.actualLabel }
    }

    private func falseSplitIndicators(_ evaluated: [EvaluatedUtterance]) -> [SpeakerNamingSimulationSplitIndicator] {
        let grouped = Dictionary(grouping: evaluated) { $0.truthSpeakerId }
        return grouped.compactMap { truthSpeakerId, values in
            let actualLabels = Set(values.map(\.actual))
            let expectedLabels = Set(values.map(\.expected))
            guard actualLabels.count > 1 else { return nil }
            if expectedLabels.count > 1 && actualLabels.isSubset(of: expectedLabels) {
                return nil
            }
            return SpeakerNamingSimulationSplitIndicator(
                truthSpeakerId: truthSpeakerId,
                actualLabels: actualLabels.sorted()
            )
        }
        .sorted { $0.truthSpeakerId < $1.truthSpeakerId }
    }

    private func identityStability(
        _ evaluated: [EvaluatedUtterance]
    ) -> (checks: Int, successes: Int, indicators: [SpeakerNamingSimulationDuplicateIdentityIndicator]) {
        let rowsWithIdentity = evaluated.compactMap { row -> (row: EvaluatedUtterance, speakerId: UUID)? in
            guard let speakerId = row.speakerId,
                  row.actual != "(missing)" else {
                return nil
            }
            return (row, speakerId)
        }
        let grouped = Dictionary(grouping: rowsWithIdentity) {
            "\($0.row.truthSpeakerId)\u{1F}\($0.row.actual)"
        }

        var checks = 0
        var successes = 0
        var indicators: [SpeakerNamingSimulationDuplicateIdentityIndicator] = []
        for values in grouped.values {
            guard values.count > 1 else { continue }
            checks += 1

            let speakerIds = Set(values.map { $0.speakerId.uuidString })
            if speakerIds.count == 1 {
                successes += 1
                continue
            }

            indicators.append(SpeakerNamingSimulationDuplicateIdentityIndicator(
                truthSpeakerId: values[0].row.truthSpeakerId,
                actualLabel: values[0].row.actual,
                speakerIds: speakerIds.sorted(),
                caseIds: Set(values.map { $0.row.caseId }).sorted()
            ))
        }

        return (
            checks,
            successes,
            indicators.sorted {
                if $0.truthSpeakerId != $1.truthSpeakerId { return $0.truthSpeakerId < $1.truthSpeakerId }
                return $0.actualLabel < $1.actualLabel
            }
        )
    }

    private func correctedTargetId(
        named name: String,
        context: ChannelSpeakerContext,
        speakerDB: SpeakerDatabase
    ) -> UUID? {
        if let target = exactNamedTarget(
            named: name,
            excluding: context.persistentSpeakerId,
            speakerDB: speakerDB
        ) {
            return target.id
        }
        guard context.sessionEmbedding != nil else {
            return context.persistentSpeakerId
        }
        return UUID()
    }

    private func exactNamedTarget(
        named rawName: String,
        excluding sourceId: UUID,
        speakerDB: SpeakerDatabase
    ) -> SpeakerProfile? {
        let targetName = normalizeName(rawName)
        guard !targetName.isEmpty else { return nil }
        return speakerDB.allSpeakers()
            .filter { $0.id != sourceId && normalizeName($0.displayName) == targetName }
            .sorted { $0.callCount > $1.callCount }
            .first
    }

    private func normalizeName(_ raw: String?) -> String {
        (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func parseSpeakerKey(_ key: String) -> (channel: UtteranceChannel, diarizerSpeakerId: Int)? {
        if key.hasPrefix("mic_"), let id = Int(key.dropFirst("mic_".count)) {
            return (.mic, id)
        }
        if key.hasPrefix("system_"), let id = Int(key.dropFirst("system_".count)) {
            return (.system, id)
        }
        return nil
    }

    private func mergeRowsResolved(sourceId: UUID, targetId: UUID, targetName: String, in directory: URL) -> Bool {
        transcriptRows(for: sourceId, in: directory).isEmpty
            && transcriptRows(for: targetId, in: directory).allNamed(targetName)
    }

    private func transcriptRows(for speakerId: UUID, in directory: URL) -> [SpeakerFrontmatterRow] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var rows: [SpeakerFrontmatterRow] = []
        for case let url as URL in enumerator where url.pathExtension == "md" {
            guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { continue }
            rows.append(contentsOf: speakerRows(in: markdown).filter { $0.dbId == speakerId })
        }
        return rows
    }

    private func speakerRows(in markdown: String) -> [SpeakerFrontmatterRow] {
        guard markdown.hasPrefix("---\n"),
              let endRange = markdown.range(
                of: "\n---\n",
                range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex
              ) else {
            return []
        }

        let frontmatterStart = markdown.index(markdown.startIndex, offsetBy: 4)
        let lines = String(markdown[frontmatterStart..<endRange.lowerBound])
            .components(separatedBy: "\n")
        var rows: [SpeakerFrontmatterRow] = []
        var index = 0

        while index < lines.count {
            guard lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("- ") else {
                index += 1
                continue
            }

            var end = index + 1
            while end < lines.count,
                  !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                end += 1
            }

            let block = lines[index..<end]
            let dbId = block.compactMap { value(for: "db_id", in: $0).flatMap(UUID.init(uuidString:)) }.first
            if let dbId {
                rows.append(SpeakerFrontmatterRow(
                    dbId: dbId,
                    name: block.compactMap { value(for: "name", in: $0) }.first
                ))
            }

            index = end
        }

        return rows
    }

    private func value(for key: String, in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\(key):") else { return nil }
        let value = trimmed.dropFirst(key.count + 1)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2,
              value.first == "\"",
              value.last == "\"" else {
            return value.isEmpty ? nil : value
        }
        return String(value.dropFirst().dropLast())
    }

    private struct Classification {
        let contexts: [String: ChannelSpeakerContext]

        func context(channel: UtteranceChannel, diarizerSpeakerId: Int) -> ChannelSpeakerContext? {
            contexts[channel.speakerKey(diarizerSpeakerId: String(diarizerSpeakerId))]
        }
    }

    private struct DeferredReviewPlan {
        let entries: [SpeakerNamingEntry]
        let redirectedSpeakerIdsByKey: [String: UUID]
        let redirectedProfiles: [DeferredReviewProfile]
    }

    private struct DeferredReviewProfile {
        let matchedProfile: SpeakerProfile
        let deferredProfileId: UUID
        let embedding: [Float]
    }

    private struct ProcessedSegment: Sendable {
        let fixture: SpeakerNamingSimulationSegment
        let effectiveSpeakerId: Int
    }

    private struct MeetingRecord {
        let id: String
        let url: URL
        let transcriptId: UUID
        let segments: [ProcessedSegment]
        let speakerIdsByKey: [String: UUID]
    }

    private struct SimulationState {
        let paths: CoreStoragePaths
        let speakerDB: SpeakerDatabase
        var records: [String: MeetingRecord] = [:]
    }

    private struct EvaluatedUtterance {
        let caseId: String
        let truthSpeakerId: String
        let expected: String
        let actual: String
        let speakerId: UUID?

        var isExactMatch: Bool {
            expected == actual
        }
    }

    private struct MeetingOutcome {
        let caseReport: SpeakerNamingSimulationCaseReport
        let evaluatedUtterances: [EvaluatedUtterance]
        let renamedChecks: Int
        let renamedSuccesses: Int
    }

    private struct PostActionOutcome {
        let checks: Int
        let successes: Int
        let notes: [String]
    }

    fileprivate struct SpeakerFrontmatterRow {
        let dbId: UUID
        let name: String?
    }

    private struct ParsedTranscriptLine {
        let timestamp: String
        let source: String
        let label: String
        let text: String
    }

    private struct NoopStatsStore: StatsStore {
        func recordSession(_ metadata: RecordingMetadata) {}
        func getTotalRecordingsCount() -> Int { 0 }
        func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] { [] }
        func recordingExists(transcriptPath: String) -> Bool { false }
    }

    private enum SimulationError: LocalizedError {
        case saveFailed(String)
        case updateFailed(String)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let meetingId):
                return "Speaker naming simulator failed to save transcript for \(meetingId)"
            case .updateFailed(let file):
                return "Speaker naming simulator failed to update \(file)"
            }
        }
    }
}

@available(macOS 14.0, *)
private extension Array where Element == SpeakerNamingSimulationRunner.SpeakerFrontmatterRow {
    func allNamed(_ name: String) -> Bool {
        !isEmpty && allSatisfy { $0.name == name }
    }
}

@available(macOS 14.0, *)
private extension Array where Element == SpeakerNamingSimulationAction {
    var containsDeferAll: Bool {
        contains {
            if case .deferAll = $0 { return true }
            return false
        }
    }

    var containsCancelBeforeNaming: Bool {
        contains {
            if case .cancelBeforeNaming = $0 { return true }
            return false
        }
    }
}

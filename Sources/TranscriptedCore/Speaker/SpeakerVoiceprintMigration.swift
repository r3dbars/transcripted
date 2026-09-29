// SpeakerVoiceprintMigration.swift
// Carries user-named people from one voiceprint model's speaker database to
// another's, so switching models doesn't forget anyone.
//
// Each voiceprint model keeps its own database file (vectors from different
// models never mix). Switching models therefore starts from an empty database
// unless something rebuilds the people the user already named. This does:
// for every person the user named (`name_source == user_manual`) it re-embeds
// the audio still on disk for them with the new model and writes a profile
// under the SAME UUID, with the same name, first/last seen, call count,
// confidence, dispute count and confirmation ledger, and exemplars rebuilt
// from the new vectors. Saved transcripts reference people by that UUID
// (`db_id`), so they stay linked.
//
// Rules it keeps:
//   - The source database is only ever read (a read-only SQLite copy into
//     memory); nothing there is written, moved or deleted.
//   - Unnamed voices are not carried; the old model's auto clusters don't
//     transfer meaningfully and the new model will find them again.
//   - Idempotent and resumable: a ledger table in the target database records
//     each person once, in the same transaction as their profile. A rerun
//     skips everyone in it; a cancel leaves finished people done and the rest
//     for next time.
//   - Off the main actor (this is an actor), cancellable through Task
//     cancellation, checked between every embedding.
//   - Quality gate: when a person's re-embedded sessions disagree with each
//     other under the new model (or there is a single clip, so agreement can't
//     be checked), the profile is still written with name and counts, but its
//     confirmations are held in the ledger, so the new model can't silently
//     name them. The first time the user confirms them under the new model,
//     that confirmation's write restores them (`recordUserConfirmations`); a
//     run also checks at start, for confirmations saved before that existed.
//   - People with no usable audio get a ledger row (`needs_confirmation`) and
//     are listed in the report instead of silently disappearing.
//
// Evidence, and where it lives: see SpeakerVoiceprintMigrationEvidence.swift.
// Decisions (ranges, pooling, the gate): SpeakerVoiceprintMigrationPolicy.swift.
// The target-side transaction and ledger: SpeakerVoiceprintMigrationLedger.swift.

import Foundation

/// Where the audio for named people lives.
public struct SpeakerVoiceprintMigrationSources: Sendable, Equatable {
    /// Folders holding saved review clips named `<profile UUID>.wav`
    /// (`CoreStoragePaths.speakerClips`, plus any legacy clip folder).
    public var speakerClipDirectories: [URL]
    /// The capture library's `meetings/` folder: saved transcripts, and their
    /// retained audio under `audio/<transcript stem>_audio/`.
    public var meetingsDirectory: URL?

    public init(speakerClipDirectories: [URL] = [], meetingsDirectory: URL? = nil) {
        self.speakerClipDirectories = speakerClipDirectories
        self.meetingsDirectory = meetingsDirectory
    }

    /// The app's layout: the configured clip folder plus the older clip folders
    /// the People list also reads (`state/speaker_clips` next to the database, and
    /// `tmp/recordings/speaker_clips` under the app-support root), and the
    /// current capture library's meetings folder.
    public static func appLayout(
        sourceDatabaseURL: URL,
        speakerClipsDirectory: URL,
        meetingsDirectory: URL
    ) -> SpeakerVoiceprintMigrationSources {
        let stateDirectory = sourceDatabaseURL.deletingLastPathComponent()
        let candidates = [
            speakerClipsDirectory,
            stateDirectory.appendingPathComponent("speaker_clips", isDirectory: true),
            stateDirectory.deletingLastPathComponent()
                .appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
        ]
        var seen: Set<String> = []
        return SpeakerVoiceprintMigrationSources(
            speakerClipDirectories: candidates.filter { seen.insert($0.standardizedFileURL.path).inserted },
            meetingsDirectory: meetingsDirectory
        )
    }
}

public struct SpeakerVoiceprintMigrationOptions: Sendable, Equatable {
    /// Most meetings re-embedded per person: meetings where the user confirmed
    /// them first, then the most recent.
    public var maxMeetingsPerPerson: Int
    /// How transcript rows become audio ranges, and the speech budget per meeting.
    public var ranges: SpeakerVoiceprintMigrationPolicy.RangeLimits
    /// Also use meetings where the old model named the person silently
    /// (`source: db`), not only ones the user named or confirmed.
    public var includeAutoRecognizedMeetings: Bool
    /// Lowest cosine two sessions of one person must reach under the new model;
    /// nil uses the new model's `matchManySegments`.
    public var agreementBar: Double?

    public init(
        maxMeetingsPerPerson: Int = 8,
        ranges: SpeakerVoiceprintMigrationPolicy.RangeLimits = .init(),
        includeAutoRecognizedMeetings: Bool = true,
        agreementBar: Double? = nil
    ) {
        self.maxMeetingsPerPerson = maxMeetingsPerPerson
        self.ranges = ranges
        self.includeAutoRecognizedMeetings = includeAutoRecognizedMeetings
        self.agreementBar = agreementBar
    }
}

public struct SpeakerVoiceprintMigrationProgress: Sendable, Equatable {
    public let completedPeople: Int
    public let totalPeople: Int
}

public struct SpeakerVoiceprintMigrationReport: Sendable, Equatable {
    public struct Person: Sendable, Equatable {
        public let profileId: UUID
        public let displayName: String
        public let status: SpeakerVoiceprintMigrationStatus
        /// Meetings and clips that produced at least one vector.
        public let sessions: Int
        public let speechSeconds: Double
        public let selfSimilarity: Double?
    }

    /// People handled in this run, in the order they were processed.
    public var people: [Person]
    /// Held people whose confirmations were restored in this run.
    public var released: [UUID]
    /// User-named people in the source that an earlier run already handled.
    public var alreadyMigrated: Int
    /// User-named people in the source.
    public var peopleInScope: Int
    /// The run stopped early; running again finishes the rest.
    public var wasCancelled: Bool

    public func ids(_ status: SpeakerVoiceprintMigrationStatus) -> [UUID] {
        people.filter { $0.status == status }.map(\.profileId)
    }
}

/// What audio exists for each named person, without embedding anything.
public struct SpeakerVoiceprintAudioInventory: Sendable, Equatable {
    public struct Person: Sendable, Equatable {
        public let profileId: UUID
        /// Saved review clips (the person's and any merged into them).
        public let clipSeconds: Double
        /// Saved meetings that name them.
        public let meetingsNamingThem: Int
        /// Of those, meetings where the user named or confirmed them.
        public let confirmedMeetings: Int
        /// Of those, meetings whose track for them is still on disk.
        public let meetingsWithAudio: Int
        /// Their speech in those meetings, from the transcript rows (no budget).
        public let meetingSpeechSeconds: Double
        /// Exemplar voiceprints in the old model, and the sessions that built them.
        /// These have no audio behind them; they show how much evidence the old
        /// voiceprint had.
        public let exemplars: Int
        public let exemplarSessions: Int
        public let confirmations: Int
        public let hasUsableAudio: Bool

        public var usableSeconds: Double { clipSeconds + meetingSpeechSeconds }
    }

    public let people: [Person]

    public var fractionWithUsableAudio: Double {
        people.isEmpty ? 0 : Double(people.filter(\.hasUsableAudio).count) / Double(people.count)
    }
}

public enum SpeakerVoiceprintMigrationError: Error, Equatable {
    case sourceDatabaseMissing
    case sourceDatabaseUnreadable
    /// The target file is the source file; the source is never written.
    case targetIsSource
    case targetDatabaseUnavailable
    /// The target database was opened with another model's thresholds.
    case thresholdsMismatch
    case alreadyRunning
    /// The new model's background load failed, so nothing can be re-embedded.
    case embedderUnavailable
}

@available(macOS 14.0, *)
public actor SpeakerVoiceprintMigration {
    private let sourceDatabaseURL: URL
    private let target: SpeakerDatabase
    private let embedder: any SpeakerSegmentEmbedder
    private let sources: SpeakerVoiceprintMigrationSources
    private let options: SpeakerVoiceprintMigrationOptions
    private var isRunning = false

    /// Migrate into a target database the host already has open (it must have
    /// been opened with `embedder.thresholds`).
    public init(
        sourceDatabaseURL: URL,
        targetDatabase: SpeakerDatabase,
        embedder: any SpeakerSegmentEmbedder,
        sources: SpeakerVoiceprintMigrationSources,
        options: SpeakerVoiceprintMigrationOptions = .init()
    ) throws {
        guard !Self.isSameFile(sourceDatabaseURL, targetDatabase.dbPath) else {
            throw SpeakerVoiceprintMigrationError.targetIsSource
        }
        guard targetDatabase.thresholds == embedder.thresholds else {
            throw SpeakerVoiceprintMigrationError.thresholdsMismatch
        }
        self.sourceDatabaseURL = sourceDatabaseURL
        self.target = targetDatabase
        self.embedder = embedder
        self.sources = sources
        self.options = options
    }

    /// Migrate into the database file at `targetDatabaseURL` (created if missing),
    /// opened with `embedder.thresholds`.
    public init(
        sourceDatabaseURL: URL,
        targetDatabaseURL: URL,
        embedder: any SpeakerSegmentEmbedder,
        sources: SpeakerVoiceprintMigrationSources,
        options: SpeakerVoiceprintMigrationOptions = .init()
    ) throws {
        guard !Self.isSameFile(sourceDatabaseURL, targetDatabaseURL) else {
            throw SpeakerVoiceprintMigrationError.targetIsSource
        }
        try self.init(
            sourceDatabaseURL: sourceDatabaseURL,
            targetDatabase: SpeakerDatabase(path: targetDatabaseURL.path, thresholds: embedder.thresholds),
            embedder: embedder,
            sources: sources,
            options: options
        )
    }

    // MARK: - Inventory

    /// What audio exists for each user-named person in the source.
    public func inventory() throws -> SpeakerVoiceprintAudioInventory {
        let snapshot = try loadSnapshot()
        let meetings = scanMeetings(for: Set(snapshot.people.map(\.id)), snapshot: snapshot)
        var unlimited = options.ranges
        unlimited.maxTotalSeconds = .greatestFiniteMagnitude

        let people = snapshot.people.map { person -> SpeakerVoiceprintAudioInventory.Person in
            let clipSeconds = clipURLs(for: person.id, snapshot: snapshot).reduce(0.0) { total, url in
                total + (SpeakerVoiceprintAudioReader.open(url).map(SpeakerVoiceprintAudioReader.duration(of:)) ?? 0)
            }
            let mine = meetings[person.id] ?? []
            var withAudio = 0
            var speech = 0.0
            for meeting in mine where !meeting.usableLabels.isEmpty {
                withAudio += 1
                guard let markdown = try? String(contentsOf: meeting.transcriptURL, encoding: .utf8) else { continue }
                let rows = SpeakerVoiceprintTranscriptScan.transcriptRows(
                    in: markdown,
                    knownLabels: meeting.labels.map(\.name)
                )
                for (channel, names) in Self.labelsByChannel(meeting.usableLabels) {
                    guard let url = meeting.tracks[channel],
                          let file = SpeakerVoiceprintAudioReader.open(url) else { continue }
                    let length = SpeakerVoiceprintAudioReader.duration(of: file)
                    speech += SpeakerVoiceprintMigrationPolicy
                        .ranges(forLabels: names, on: channel, rows: rows, limits: unlimited)
                        .reduce(0.0) { $0 + max(0, min($1.end, length) - $1.start) }
                }
            }
            let stats = snapshot.exemplarStats[person.id]
            return SpeakerVoiceprintAudioInventory.Person(
                profileId: person.id,
                clipSeconds: clipSeconds,
                meetingsNamingThem: mine.count,
                confirmedMeetings: mine.filter(\.confirmed).count,
                meetingsWithAudio: withAudio,
                meetingSpeechSeconds: speech,
                exemplars: stats?.count ?? 0,
                exemplarSessions: stats?.sessions ?? 0,
                confirmations: snapshot.confirmations[person.id]?.count ?? 0,
                hasUsableAudio: clipSeconds + speech >= options.ranges.minSeconds
            )
        }
        return SpeakerVoiceprintAudioInventory(people: people)
    }

    // MARK: - Run

    /// Carry every user-named person not yet in the ledger. Cancel the calling
    /// task to stop; the report says `wasCancelled` and a later run resumes.
    public func run(
        progress: (@Sendable (SpeakerVoiceprintMigrationProgress) -> Void)? = nil
    ) async throws -> SpeakerVoiceprintMigrationReport {
        guard !isRunning else { throw SpeakerVoiceprintMigrationError.alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        guard target.isOpenForVoiceprintMigration else {
            throw SpeakerVoiceprintMigrationError.targetDatabaseUnavailable
        }
        // A background-loaded model finishes loading before anyone moves. If it
        // can't load, nobody is written to the ledger, so the next launch retries.
        if let loading = embedder as? any BackgroundLoadingSpeakerSegmentEmbedder,
           await !loading.waitUntilLoaded() {
            throw SpeakerVoiceprintMigrationError.embedderUnavailable
        }
        let snapshot = try loadSnapshot()
        try target.ensureVoiceprintMigrationLedger()

        var report = SpeakerVoiceprintMigrationReport(
            people: [],
            released: try target.releaseHeldVoiceprintConfirmations(),
            alreadyMigrated: 0,
            peopleInScope: snapshot.people.count,
            wasCancelled: false
        )
        let done = Set(target.voiceprintMigrationLedger().map(\.profileId))
        let pending = snapshot.people.filter { !done.contains($0.id) }
        report.alreadyMigrated = snapshot.people.count - pending.count
        guard !pending.isEmpty else { return finish(report) }

        let meetings = scanMeetings(for: Set(pending.map(\.id)), snapshot: snapshot)
        guard !Task.isCancelled else {
            report.wasCancelled = true
            return finish(report)
        }
        progress?(SpeakerVoiceprintMigrationProgress(completedPeople: 0, totalPeople: pending.count))

        for (index, person) in pending.enumerated() {
            guard let sessions = embedSessions(for: person, meetings: meetings[person.id] ?? [], snapshot: snapshot) else {
                report.wasCancelled = true
                break
            }
            let write = plan(person, sessions: sessions, snapshot: snapshot)
            let status = try target.writeVoiceprintMigrationPerson(write)
            report.people.append(SpeakerVoiceprintMigrationReport.Person(
                profileId: person.id,
                displayName: person.displayName,
                status: status,
                sessions: write.sessions,
                speechSeconds: write.speechSeconds,
                selfSimilarity: write.selfSimilarity
            ))
            progress?(SpeakerVoiceprintMigrationProgress(completedPeople: index + 1, totalPeople: pending.count))
            await Task.yield()
            if Task.isCancelled, index + 1 < pending.count {
                report.wasCancelled = true
                break
            }
        }
        return finish(report)
    }

    // MARK: - Evidence

    /// One recording's worth of a person's voice: a meeting, or a review clip.
    private struct Session {
        let pieces: [SpeakerVoiceprintMigrationPolicy.Piece]
    }

    /// Embed every session for `person`, oldest meeting first and review clips
    /// last (they are the most recent review). Nil when the task was cancelled.
    private func embedSessions(
        for person: SpeakerVoiceprintSourceSnapshot.Person,
        meetings: [SpeakerVoiceprintMeetingEvidence],
        snapshot: SpeakerVoiceprintSourceSnapshot
    ) -> [Session]? {
        var sessions: [Session] = []
        let chosen = meetings
            .filter { !$0.usableLabels.isEmpty && (options.includeAutoRecognizedMeetings || $0.confirmed) }
            .sorted { lhs, rhs in
                if lhs.confirmed != rhs.confirmed { return lhs.confirmed }
                let lhsDate = lhs.recordedAt ?? .distantPast
                let rhsDate = rhs.recordedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.transcriptURL.path < rhs.transcriptURL.path
            }
            .prefix(max(0, options.maxMeetingsPerPerson))
            .sorted { ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }

        for meeting in chosen {
            guard let markdown = try? String(contentsOf: meeting.transcriptURL, encoding: .utf8) else { continue }
            let rows = SpeakerVoiceprintTranscriptScan.transcriptRows(
                in: markdown,
                knownLabels: meeting.labels.map(\.name)
            )
            var pieces: [SpeakerVoiceprintMigrationPolicy.Piece] = []
            for (channel, names) in Self.labelsByChannel(meeting.usableLabels) {
                let ranges = SpeakerVoiceprintMigrationPolicy.ranges(
                    forLabels: names, on: channel, rows: rows, limits: options.ranges
                )
                guard !ranges.isEmpty,
                      let url = meeting.tracks[channel],
                      let file = SpeakerVoiceprintAudioReader.open(url) else { continue }
                for range in ranges {
                    if Task.isCancelled { return nil }
                    guard let samples = SpeakerVoiceprintAudioReader.samples(from: file, range: range),
                          let vector = embed(samples) else { continue }
                    pieces.append(.init(
                        embedding: vector,
                        seconds: Double(samples.count) / Double(SpeakerVoiceprintAudioReader.sampleRate)
                    ))
                }
            }
            if !pieces.isEmpty { sessions.append(Session(pieces: pieces)) }
        }

        for url in clipURLs(for: person.id, snapshot: snapshot) {
            if Task.isCancelled { return nil }
            guard let file = SpeakerVoiceprintAudioReader.open(url) else { continue }
            let whole = SpeakerVoiceprintMigrationPolicy.TimeRange(
                start: 0, end: SpeakerVoiceprintAudioReader.duration(of: file)
            )
            guard whole.seconds >= options.ranges.minSeconds,
                  let samples = SpeakerVoiceprintAudioReader.samples(from: file, range: whole),
                  let vector = embed(samples) else { continue }
            sessions.append(Session(pieces: [.init(
                embedding: vector,
                seconds: Double(samples.count) / Double(SpeakerVoiceprintAudioReader.sampleRate)
            )]))
        }
        return sessions
    }

    private func plan(
        _ person: SpeakerVoiceprintSourceSnapshot.Person,
        sessions: [Session],
        snapshot: SpeakerVoiceprintSourceSnapshot
    ) -> SpeakerVoiceprintMigrationWrite {
        let bar = options.agreementBar ?? embedder.thresholds.matchManySegments
        let assessment = SpeakerVoiceprintMigrationPolicy.assess(sessions: sessions.map(\.pieces), agreementBar: bar)
        let speech = sessions.flatMap(\.pieces).reduce(0.0) { $0 + $1.seconds }
        let status: SpeakerVoiceprintMigrationStatus
        var exemplarMeans: [[Float]] = []
        if let assessment {
            status = assessment.isConsistent ? .carried : .held
            if assessment.isConsistent {
                exemplarMeans = assessment.agreeingSessions.map { assessment.sessionMeans[$0] }
            }
        } else {
            status = .needsConfirmation
        }
        return SpeakerVoiceprintMigrationWrite(
            person: person,
            status: status,
            embedderIdentifier: embedder.identifier,
            centroid: assessment?.centroid,
            exemplarMeans: exemplarMeans,
            confirmations: snapshot.confirmations[person.id] ?? [],
            outcomes: snapshot.recentOutcomes[person.id] ?? [],
            sessions: assessment?.sessionMeans.count ?? 0,
            speechSeconds: speech,
            selfSimilarity: assessment?.selfSimilarity
        )
    }

    private func embed(_ samples: [Float]) -> [Float]? {
        guard let vector = embedder.embed(samples: samples, sampleRate: SpeakerVoiceprintAudioReader.sampleRate),
              vector.count == embedder.dimension,
              vector.allSatisfy(\.isFinite),
              vector.contains(where: { $0 != 0 }) else { return nil }
        return SpeakerVectorMath.l2Normalize(vector)
    }

    // MARK: - Helpers

    private func loadSnapshot() throws -> SpeakerVoiceprintSourceSnapshot {
        do {
            return try SpeakerVoiceprintSourceSnapshot.load(from: sourceDatabaseURL)
        } catch SpeakerVoiceprintSourceSnapshot.LoadError.missing {
            throw SpeakerVoiceprintMigrationError.sourceDatabaseMissing
        } catch {
            throw SpeakerVoiceprintMigrationError.sourceDatabaseUnreadable
        }
    }

    private func scanMeetings(
        for peopleIds: Set<UUID>,
        snapshot: SpeakerVoiceprintSourceSnapshot
    ) -> [UUID: [SpeakerVoiceprintMeetingEvidence]] {
        guard let directory = sources.meetingsDirectory else { return [:] }
        return SpeakerVoiceprintTranscriptScan.meetings(
            under: directory,
            snapshot: snapshot,
            peopleIds: peopleIds,
            isCancelled: { Task.isCancelled }
        )
    }

    /// Review clips for `profileId` and every profile merged into it, once each.
    private func clipURLs(for profileId: UUID, snapshot: SpeakerVoiceprintSourceSnapshot) -> [URL] {
        var seen: Set<String> = []
        var urls: [URL] = []
        for id in snapshot.absorbedIds(into: profileId) {
            for directory in sources.speakerClipDirectories {
                let url = directory.appendingPathComponent("\(id.uuidString).wav")
                guard FileManager.default.fileExists(atPath: url.path),
                      seen.insert(url.standardizedFileURL.resolvingSymlinksInPath().path).inserted else { continue }
                urls.append(url)
            }
        }
        return urls
    }

    private static func labelsByChannel(
        _ labels: Set<SpeakerVoiceprintMeetingEvidence.Label>
    ) -> [(UtteranceChannel, Set<String>)] {
        [UtteranceChannel.system, .mic].compactMap { channel in
            let names = Set(labels.filter { $0.channel == channel }.map(\.name))
            return names.isEmpty ? nil : (channel, names)
        }
    }

    private static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func finish(_ report: SpeakerVoiceprintMigrationReport) -> SpeakerVoiceprintMigrationReport {
        AppLogger.speakers.info("Voiceprint migration pass finished", [
            "in_scope": "\(report.peopleInScope)",
            "already_migrated": "\(report.alreadyMigrated)",
            "carried": "\(report.ids(.carried).count)",
            "held": "\(report.ids(.held).count)",
            "needs_confirmation": "\(report.ids(.needsConfirmation).count)",
            "already_present": "\(report.ids(.alreadyPresent).count)",
            "released": "\(report.released.count)",
            "cancelled": "\(report.wasCancelled)",
        ])
        return report
    }
}

@available(macOS 14.0, *)
extension SpeakerDatabase {
    var isOpenForVoiceprintMigration: Bool {
        queue.sync { isDatabaseOpen }
    }
}

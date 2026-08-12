import ArgumentParser
import Foundation

/// Report speaker-recognition lifeline metrics from speakers.sqlite.
///
/// Reads the append-only `speaker_match_outcomes` table the app writes on
/// every auto-recognition and review verdict, and prints the funnel plus the
/// two north-star numbers with 30-day trend direction:
///   1. recognition precision (should trend up)
///   2. questions per meeting (should trend down)
/// Prints counts and buckets only — never speaker names.
struct SpeakerStats: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speaker-stats",
        abstract: "Report speaker-recognition lifeline metrics: funnel, precision, and 30-day trends."
    )

    @OptionGroup var pathOpts: PathOptions
    @OptionGroup var formatOpts: FormatOptions

    func run() throws {
        let stateDir = pathOpts.resolved.stateDir
        let candidates = [
            ("WeSpeaker", stateDir.appendingPathComponent("speakers.sqlite").path),
            ("ERes2Net", stateDir.appendingPathComponent("speakers_eres2net.sqlite").path),
        ].filter { FileManager.default.fileExists(atPath: $0.1) }

        guard !candidates.isEmpty else {
            print("No speaker database found under \(stateDir.path)")
            throw ExitCode(1)
        }

        var reports: [SpeakerLifelineReport] = []
        for (embedder, path) in candidates {
            let reader = try SQLiteReader(path: path)
            reports.append(try Self.buildReport(embedder: embedder, path: path, reader: reader, now: Date()))
        }

        switch formatOpts.format {
        case .text:
            for report in reports {
                print(report.renderText())
                print("")
            }
        case .json:
            let data = try JSONSerialization.data(
                withJSONObject: reports.map { $0.jsonObject() },
                options: [.prettyPrinted, .sortedKeys]
            )
            print(String(data: data, encoding: .utf8) ?? "[]")
        }
    }

    static func buildReport(
        embedder: String,
        path: String,
        reader: SQLiteReader,
        now: Date
    ) throws -> SpeakerLifelineReport {
        // dispute_count is a migration-added column and the reader is
        // read-only, so a legacy DB the current app has never opened may
        // lack it — degrade to zero disputes instead of failing the report.
        let speakerColumns = Set((try reader.tableColumns("speakers")).map(\.name))
        let disputeSelect = speakerColumns.contains("dispute_count") ? "dispute_count" : "0 AS dispute_count"
        let profileRows = try reader.query(
            "SELECT display_name, call_count, \(disputeSelect) FROM speakers;"
        )
        let totalProfiles = profileRows.count
        let namedProfiles = profileRows.filter {
            if let name = $0["display_name"] as? String { return !name.isEmpty }
            return false
        }.count
        let disputedProfiles = profileRows.filter {
            (($0["dispute_count"] as? Int64) ?? 0) > 0
        }.count

        let tableProbe = try reader.query(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='speaker_match_outcomes' LIMIT 1;"
        )
        let hasOutcomeTable = !tableProbe.isEmpty
        let outcomes: [SpeakerLifelineOutcome]
        if hasOutcomeTable {
            let rows = try reader.query("""
                SELECT profile_id, kind, call_count_at_match, transcript_id, recorded_at
                FROM speaker_match_outcomes ORDER BY recorded_at ASC;
                """)
            let isoFormatter = ISO8601DateFormatter()
            outcomes = rows.compactMap { row in
                guard let profileId = row["profile_id"] as? String,
                      let kind = row["kind"] as? String,
                      let recordedAtRaw = row["recorded_at"] as? String,
                      let recordedAt = isoFormatter.date(from: recordedAtRaw) else {
                    return nil
                }
                return SpeakerLifelineOutcome(
                    profileId: profileId,
                    kind: kind,
                    callCountAtMatch: (row["call_count_at_match"] as? Int64).map(Int.init),
                    transcriptId: row["transcript_id"] as? String,
                    recordedAt: recordedAt
                )
            }
        } else {
            outcomes = []
        }

        let confirmationProbe = try reader.query(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='speaker_profile_confirmations' LIMIT 1;"
        )
        let hasConfirmationLedger = !confirmationProbe.isEmpty
        let confirmations: [SpeakerLifelineConfirmation]?
        if hasConfirmationLedger {
            let rows = try reader.query("""
                SELECT id, profile_id, transcript_id, confirmed_at
                FROM speaker_profile_confirmations ORDER BY confirmed_at ASC;
                """)
            let isoFormatter = ISO8601DateFormatter()
            confirmations = rows.compactMap { row in
                guard let id = row["id"] as? String,
                      let profileId = row["profile_id"] as? String,
                      let transcriptId = row["transcript_id"] as? String,
                      let confirmedAtRaw = row["confirmed_at"] as? String,
                      let confirmedAt = isoFormatter.date(from: confirmedAtRaw) else {
                    return nil
                }
                return SpeakerLifelineConfirmation(
                    id: id,
                    profileId: profileId,
                    transcriptId: transcriptId,
                    confirmedAt: confirmedAt
                )
            }
        } else {
            confirmations = nil
        }

        let mergeEventProbe = try reader.query(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='speaker_merge_events' LIMIT 1;"
        )
        let confirmationMoveProbe = try reader.query(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='speaker_confirmation_moves' LIMIT 1;"
        )
        let hasConfirmationLineage = !mergeEventProbe.isEmpty && !confirmationMoveProbe.isEmpty
        let mergeEvents: [SpeakerLifelineMergeEvent]
        let confirmationMoves: [SpeakerLifelineConfirmationMove]
        if hasConfirmationLineage {
            let isoFormatter = ISO8601DateFormatter()
            mergeEvents = try reader.query("""
                SELECT rowid, id, source_id, target_id, merged_at, undone_at
                FROM speaker_merge_events ORDER BY rowid ASC;
                """).compactMap { row in
                guard let sequence = row["rowid"] as? Int64,
                      let id = row["id"] as? String,
                      let sourceProfileId = row["source_id"] as? String,
                      let targetProfileId = row["target_id"] as? String,
                      let mergedAtRaw = row["merged_at"] as? String,
                      let mergedAt = isoFormatter.date(from: mergedAtRaw) else {
                    return nil
                }
                let undoneAt = (row["undone_at"] as? String).flatMap {
                    isoFormatter.date(from: $0)
                }
                return SpeakerLifelineMergeEvent(
                    id: id,
                    sourceProfileId: sourceProfileId,
                    targetProfileId: targetProfileId,
                    mergedAt: mergedAt,
                    undoneAt: undoneAt,
                    sequence: sequence
                )
            }
            confirmationMoves = try reader.query("""
                SELECT merge_event_id, confirmation_id, source_profile_id,
                       target_profile_id, transcript_id, confirmed_at
                FROM speaker_confirmation_moves;
                """).compactMap { row in
                guard let mergeEventId = row["merge_event_id"] as? String,
                      let confirmationId = row["confirmation_id"] as? String,
                      let sourceProfileId = row["source_profile_id"] as? String,
                      let targetProfileId = row["target_profile_id"] as? String,
                      let transcriptId = row["transcript_id"] as? String,
                      let confirmedAtRaw = row["confirmed_at"] as? String,
                      let confirmedAt = isoFormatter.date(from: confirmedAtRaw) else {
                    return nil
                }
                return SpeakerLifelineConfirmationMove(
                    mergeEventId: mergeEventId,
                    confirmationId: confirmationId,
                    sourceProfileId: sourceProfileId,
                    targetProfileId: targetProfileId,
                    transcriptId: transcriptId,
                    confirmedAt: confirmedAt
                )
            }
        } else {
            mergeEvents = []
            confirmationMoves = []
        }

        return SpeakerLifelineReport(
            embedder: embedder,
            databasePath: path,
            hasOutcomeTable: hasOutcomeTable,
            hasConfirmationLedger: hasConfirmationLedger,
            totalProfiles: totalProfiles,
            namedProfiles: namedProfiles,
            disputedProfiles: disputedProfiles,
            metrics: SpeakerLifelineMetrics.compute(
                outcomes: outcomes,
                confirmations: confirmations,
                confirmationMoves: confirmationMoves,
                mergeEvents: mergeEvents,
                now: now
            )
        )
    }
}

// MARK: - Outcome + metric math (pure, unit-testable)

struct SpeakerLifelineOutcome {
    let profileId: String
    let kind: String
    let callCountAtMatch: Int?
    let transcriptId: String?
    let recordedAt: Date

    var isAutoAccepted: Bool { kind == "auto_accepted" }
    /// Review verdicts require a user answer — these are the "questions".
    var isReviewVerdict: Bool {
        ["confirmed", "corrected", "named", "merged"].contains(kind)
    }
    /// Verdicts on a suggested match, the precision numerator/denominator.
    var isSuggestionVerdict: Bool {
        kind == "confirmed" || kind == "corrected"
    }
}

struct SpeakerLifelineConfirmation {
    let id: String
    let profileId: String
    let transcriptId: String
    let confirmedAt: Date
}

struct SpeakerLifelineConfirmationMove {
    let mergeEventId: String
    let confirmationId: String
    let sourceProfileId: String
    let targetProfileId: String
    let transcriptId: String
    let confirmedAt: Date
}

struct SpeakerLifelineMergeEvent {
    let id: String
    let sourceProfileId: String
    let targetProfileId: String
    let mergedAt: Date
    let undoneAt: Date?
    let sequence: Int64
}

struct SpeakerLifelineWindowStats {
    var autoRecognitions = 0
    var confirmed = 0
    var corrected = 0
    var questions = 0
    var meetings = 0

    /// confirmed / (confirmed + corrected); nil when there were no suggestion verdicts.
    var suggestionPrecision: Double? {
        let total = confirmed + corrected
        guard total > 0 else { return nil }
        return Double(confirmed) / Double(total)
    }

    var questionsPerMeeting: Double? {
        guard meetings > 0 else { return nil }
        return Double(questions) / Double(meetings)
    }
}

struct SpeakerLifelineMetrics {
    let graduatedProfiles: Int
    /// Distinct explicit confirmations present before each profile's first
    /// auto-recognition. Nil when the canonical confirmation ledger is absent.
    let confirmedMeetingsToGraduation: [Int]?
    let allTime: SpeakerLifelineWindowStats
    let last30Days: SpeakerLifelineWindowStats
    let prior30Days: SpeakerLifelineWindowStats

    var medianConfirmedMeetingsToGraduation: Double? {
        guard let confirmedMeetingsToGraduation,
              !confirmedMeetingsToGraduation.isEmpty else { return nil }
        let middle = confirmedMeetingsToGraduation.count / 2
        if confirmedMeetingsToGraduation.count.isMultiple(of: 2) {
            return (
                Double(confirmedMeetingsToGraduation[middle - 1])
                    + Double(confirmedMeetingsToGraduation[middle])
            ) / 2
        }
        return Double(confirmedMeetingsToGraduation[middle])
    }

    static func compute(
        outcomes: [SpeakerLifelineOutcome],
        confirmations: [SpeakerLifelineConfirmation]?,
        confirmationMoves: [SpeakerLifelineConfirmationMove] = [],
        mergeEvents: [SpeakerLifelineMergeEvent] = [],
        now: Date
    ) -> SpeakerLifelineMetrics {
        var firstAutoByProfile: [String: SpeakerLifelineOutcome] = [:]
        for outcome in outcomes where outcome.isAutoAccepted {
            if let existing = firstAutoByProfile[outcome.profileId] {
                if outcome.recordedAt < existing.recordedAt {
                    firstAutoByProfile[outcome.profileId] = outcome
                }
            } else {
                firstAutoByProfile[outcome.profileId] = outcome
            }
        }
        let confirmationsToGraduation = confirmations.map { confirmations in
            let proofs = confirmationProofs(
                current: confirmations,
                moves: confirmationMoves,
                mergeEvents: mergeEvents
            )
            return firstAutoByProfile.values.map { firstAuto in
                Set<String>(proofs.lazy.compactMap { proof -> String? in
                    // Legacy rows are stored at whole-second precision across
                    // separate tables, so equality has no trustworthy ordering.
                    // Exclude that ambiguous second rather than risk counting a
                    // confirmation that was recorded just after the auto-match.
                    guard proof.confirmedAt < firstAuto.recordedAt,
                          confirmationOwner(
                            proof,
                            at: firstAuto.recordedAt,
                            mergeEvents: mergeEvents
                          ) == firstAuto.profileId else {
                        return nil
                    }
                    return proof.transcriptId
                }).count
            }.sorted()
        }

        let last30Start = now.addingTimeInterval(-30 * 24 * 3600)
        let prior30Start = now.addingTimeInterval(-60 * 24 * 3600)

        func stats(_ slice: [SpeakerLifelineOutcome]) -> SpeakerLifelineWindowStats {
            var stats = SpeakerLifelineWindowStats()
            var meetingIds = Set<String>()
            for outcome in slice {
                if outcome.isAutoAccepted { stats.autoRecognitions += 1 }
                if outcome.kind == "confirmed" { stats.confirmed += 1 }
                if outcome.kind == "corrected" { stats.corrected += 1 }
                if outcome.isReviewVerdict { stats.questions += 1 }
                if let transcriptId = outcome.transcriptId { meetingIds.insert(transcriptId) }
            }
            stats.meetings = meetingIds.count
            return stats
        }

        return SpeakerLifelineMetrics(
            graduatedProfiles: firstAutoByProfile.count,
            confirmedMeetingsToGraduation: confirmationsToGraduation,
            allTime: stats(outcomes),
            last30Days: stats(outcomes.filter { $0.recordedAt >= last30Start }),
            prior30Days: stats(outcomes.filter { $0.recordedAt >= prior30Start && $0.recordedAt < last30Start })
        )
    }

    /// Rebuild every logical confirmation proof, including a source row that
    /// was deleted because its meeting already existed on the merge target.
    /// The move journal retains that row's original id and timestamp.
    private static func confirmationProofs(
        current: [SpeakerLifelineConfirmation],
        moves: [SpeakerLifelineConfirmationMove],
        mergeEvents: [SpeakerLifelineMergeEvent]
    ) -> [ConfirmationProof] {
        let eventsById = Dictionary(uniqueKeysWithValues: mergeEvents.map { ($0.id, $0) })
        let currentById = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let movesByConfirmation = Dictionary(grouping: moves, by: \.confirmationId)
        let confirmationIds = Set(currentById.keys).union(movesByConfirmation.keys)

        return confirmationIds.compactMap { confirmationId in
            let orderedMoves = (movesByConfirmation[confirmationId] ?? []).sorted { lhs, rhs in
                let left = eventsById[lhs.mergeEventId]?.sequence ?? Int64.max
                let right = eventsById[rhs.mergeEventId]?.sequence ?? Int64.max
                return left < right
            }
            if let firstMove = orderedMoves.first {
                return ConfirmationProof(
                    initialProfileId: firstMove.sourceProfileId,
                    transcriptId: firstMove.transcriptId,
                    confirmedAt: firstMove.confirmedAt,
                    moves: orderedMoves
                )
            }
            guard let row = currentById[confirmationId] else { return nil }
            return ConfirmationProof(
                initialProfileId: row.profileId,
                transcriptId: row.transcriptId,
                confirmedAt: row.confirmedAt,
                moves: []
            )
        }
    }

    /// Resolve one proof's owner at a historical instant by replaying its
    /// journaled merge and unmerge transitions. This prevents a later merge
    /// from either erasing the source profile's graduation proof or lending it
    /// confirmations that belonged to a different person at that time.
    private static func confirmationOwner(
        _ proof: ConfirmationProof,
        at date: Date,
        mergeEvents: [SpeakerLifelineMergeEvent]
    ) -> String {
        struct Transition {
            let date: Date
            let sequence: Int64
            let isUndo: Bool
            let sourceProfileId: String
            let targetProfileId: String
        }

        let eventsById = Dictionary(uniqueKeysWithValues: mergeEvents.map { ($0.id, $0) })
        var transitions: [Transition] = []
        for move in proof.moves {
            guard let event = eventsById[move.mergeEventId] else { continue }
            transitions.append(Transition(
                date: event.mergedAt,
                sequence: event.sequence,
                isUndo: false,
                sourceProfileId: move.sourceProfileId,
                targetProfileId: move.targetProfileId
            ))
            if let undoneAt = event.undoneAt {
                transitions.append(Transition(
                    date: undoneAt,
                    sequence: event.sequence,
                    isUndo: true,
                    sourceProfileId: move.sourceProfileId,
                    targetProfileId: move.targetProfileId
                ))
            }
        }
        transitions.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            return !lhs.isUndo && rhs.isUndo
        }

        var owner = proof.initialProfileId
        for transition in transitions where transition.date <= date {
            if transition.isUndo {
                if owner == transition.targetProfileId {
                    owner = transition.sourceProfileId
                }
            } else if owner == transition.sourceProfileId {
                owner = transition.targetProfileId
            }
        }
        return owner
    }

    private struct ConfirmationProof {
        let initialProfileId: String
        let transcriptId: String
        let confirmedAt: Date
        let moves: [SpeakerLifelineConfirmationMove]
    }
}

// MARK: - Report rendering

struct SpeakerLifelineReport {
    let embedder: String
    let databasePath: String
    let hasOutcomeTable: Bool
    let hasConfirmationLedger: Bool
    let totalProfiles: Int
    let namedProfiles: Int
    let disputedProfiles: Int
    let metrics: SpeakerLifelineMetrics

    func renderText() -> String {
        var lines: [String] = []
        lines.append("Speaker recognition lifeline — \(embedder) (\(databasePath))")
        lines.append("Profiles: \(totalProfiles) total · \(namedProfiles) named · \(metrics.graduatedProfiles) auto-recognized · \(disputedProfiles) disputed")

        guard hasOutcomeTable else {
            lines.append("No lifeline data yet — the speaker_match_outcomes table appears after the first meeting on this app version.")
            return lines.joined(separator: "\n")
        }

        if let median = metrics.medianConfirmedMeetingsToGraduation {
            let formattedMedian = median.rounded() == median
                ? String(Int(median))
                : String(format: "%.1f", median)
            lines.append("Graduation: median \(formattedMedian) explicitly confirmed meetings to first auto-recognition")
        } else if !hasConfirmationLedger {
            lines.append("Graduation: confirmation ledger unavailable until this database is opened by the current app")
        } else if metrics.graduatedProfiles > 0 {
            lines.append("Graduation: auto-recognition exists, but no qualifying explicit-confirmation history was found")
        } else {
            lines.append("Graduation: no profile has been auto-recognized yet")
        }

        lines.append("All time: \(metrics.allTime.autoRecognitions) auto-recognitions · \(metrics.allTime.confirmed) confirmed · \(metrics.allTime.corrected) corrected · \(metrics.allTime.questions) questions across \(metrics.allTime.meetings) reviewed meetings")

        lines.append("Last 30 days vs prior 30 days (up-arrow good for precision, down-arrow good for questions):")
        lines.append("  recognition precision  " + Self.trendLine(
            current: metrics.last30Days.suggestionPrecision,
            previous: metrics.prior30Days.suggestionPrecision,
            format: Self.percent,
            improvesWhenRising: true
        ))
        lines.append("  questions per meeting  " + Self.trendLine(
            current: metrics.last30Days.questionsPerMeeting,
            previous: metrics.prior30Days.questionsPerMeeting,
            format: { String(format: "%.1f", $0) },
            improvesWhenRising: false
        ))
        lines.append("  auto-recognitions      \(metrics.last30Days.autoRecognitions) (prior: \(metrics.prior30Days.autoRecognitions))")
        return lines.joined(separator: "\n")
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    static func trendLine(
        current: Double?,
        previous: Double?,
        format: (Double) -> String,
        improvesWhenRising: Bool
    ) -> String {
        guard let current else { return "no data in the last 30 days" }
        guard let previous else { return "\(format(current)) (no prior-window data)" }
        let arrow: String
        let delta = current - previous
        if abs(delta) < 0.005 {
            arrow = "→ steady"
        } else if (delta > 0) == improvesWhenRising {
            arrow = delta > 0 ? "↑ improving" : "↓ improving"
        } else {
            arrow = delta > 0 ? "↑ regressing" : "↓ regressing"
        }
        return "\(format(current)) \(arrow) (prior: \(format(previous)))"
    }

    func jsonObject() -> [String: Any] {
        func windowObject(_ stats: SpeakerLifelineWindowStats) -> [String: Any] {
            var object: [String: Any] = [
                "auto_recognitions": stats.autoRecognitions,
                "confirmed": stats.confirmed,
                "corrected": stats.corrected,
                "questions": stats.questions,
                "reviewed_meetings": stats.meetings,
            ]
            if let precision = stats.suggestionPrecision {
                object["suggestion_precision"] = precision
            }
            if let perMeeting = stats.questionsPerMeeting {
                object["questions_per_meeting"] = perMeeting
            }
            return object
        }

        var object: [String: Any] = [
            "embedder": embedder,
            "database_path": databasePath,
            "has_lifeline_data": hasOutcomeTable,
            "has_confirmation_ledger": hasConfirmationLedger,
            "profiles_total": totalProfiles,
            "profiles_named": namedProfiles,
            "profiles_disputed": disputedProfiles,
            "profiles_auto_recognized": metrics.graduatedProfiles,
            "all_time": windowObject(metrics.allTime),
            "last_30_days": windowObject(metrics.last30Days),
            "prior_30_days": windowObject(metrics.prior30Days),
        ]
        if let median = metrics.medianConfirmedMeetingsToGraduation {
            object["median_confirmed_meetings_to_graduation"] = median
        }
        return object
    }
}

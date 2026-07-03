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

        return SpeakerLifelineReport(
            embedder: embedder,
            databasePath: path,
            hasOutcomeTable: hasOutcomeTable,
            totalProfiles: totalProfiles,
            namedProfiles: namedProfiles,
            disputedProfiles: disputedProfiles,
            metrics: SpeakerLifelineMetrics.compute(outcomes: outcomes, now: now)
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
    /// call_count_at_match of each profile's first auto-recognition, sorted.
    let appearancesToGraduation: [Int]
    let allTime: SpeakerLifelineWindowStats
    let last30Days: SpeakerLifelineWindowStats
    let prior30Days: SpeakerLifelineWindowStats

    var medianAppearancesToGraduation: Int? {
        guard !appearancesToGraduation.isEmpty else { return nil }
        return appearancesToGraduation[appearancesToGraduation.count / 2]
    }

    static func compute(outcomes: [SpeakerLifelineOutcome], now: Date) -> SpeakerLifelineMetrics {
        // call_count_at_match is the profile's pre-meeting call count, so the
        // appearance number of the graduation meeting itself is count + 1.
        var firstAutoByProfile: [String: Int?] = [:]
        for outcome in outcomes where outcome.isAutoAccepted {
            if firstAutoByProfile[outcome.profileId] == nil {
                firstAutoByProfile[outcome.profileId] = outcome.callCountAtMatch.map { $0 + 1 }
            }
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
            appearancesToGraduation: firstAutoByProfile.values.compactMap { $0 }.sorted(),
            allTime: stats(outcomes),
            last30Days: stats(outcomes.filter { $0.recordedAt >= last30Start }),
            prior30Days: stats(outcomes.filter { $0.recordedAt >= prior30Start && $0.recordedAt < last30Start })
        )
    }
}

// MARK: - Report rendering

struct SpeakerLifelineReport {
    let embedder: String
    let databasePath: String
    let hasOutcomeTable: Bool
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

        if let median = metrics.medianAppearancesToGraduation {
            lines.append("Graduation: median \(median) appearances to first auto-recognition")
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
            "profiles_total": totalProfiles,
            "profiles_named": namedProfiles,
            "profiles_disputed": disputedProfiles,
            "profiles_auto_recognized": metrics.graduatedProfiles,
            "all_time": windowObject(metrics.allTime),
            "last_30_days": windowObject(metrics.last30Days),
            "prior_30_days": windowObject(metrics.prior30Days),
        ]
        if let median = metrics.medianAppearancesToGraduation {
            object["median_appearances_to_graduation"] = median
        }
        return object
    }
}

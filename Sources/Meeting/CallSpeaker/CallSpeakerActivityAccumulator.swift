// CallSpeakerActivityAccumulator.swift
// Folds one recording's poll snapshots into `CallSpeakerActivity`: speaking
// spans, the spans where the read was trustworthy (coverage), the roster and
// the local user's names. Pure value type; the caller passes each poll's time
// (seconds from recording start, the midpoint of the read).
//
// Timeline rules (unverified against live calls):
// - A poll's speaker is the one person other than the local user shown as
//   speaking. Nobody, or two or more at once, is no speaker.
// - A span opens on a speaker, and closes on a different speaker, no
//   speaker, or a gap of more than `maxObservationGap` between polls. Polls
//   run every 1 s and a read can take up to 1.5 s; each is timed at its read's
//   midpoint, so back-to-back polls can land up to about 2.5 s apart.
// - A withheld poll (truncated, ambiguous or disagreeing windows) adds no
//   evidence either way; it only closes a span when the gap check would.
// - Spans shorter than `minSpanSeconds` are dropped; at most `maxSpans` kept.
// - Teams spans move `teamsLagSeconds` earlier (its indicator lags).
// - Coverage spans run alongside: open while polls show exactly one other
//   speaker, so every interval lies inside a coverage span (the Core policy
//   clips intervals to coverage).
// - The roster and the local user's names accumulate from every poll except
//   `.multipleWindows` (tiles from another meeting may be mixed in). An app
//   without self detection (`CallSpeakerApp.detectsSelf`, Slack today) adds
//   to the roster only from polls where a self marker was found anyway, so
//   its roster does not knowingly include an unmarked local tile. Rosters
//   are metadata only; Core never names a voice from roster-only observations.

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct CallSpeakerActivityAccumulator: Sendable {
    static let maxObservationGap: Double = 2.5
    static let minSpanSeconds: Double = 0.4
    static let maxSpans = 2000
    static let teamsLagSeconds: Double = 1.5

    private struct OpenSpan: Sendable {
        let start: Double
        let shift: Double
    }

    private var intervals: [CallSpeakerActivity.Interval] = []
    private var coverage: [CallSpeakerActivity.Span] = []
    private var roster: [String] = []
    private var selfNames = Set<String>()
    private var sawSpeakingIndicator = false

    private var openSpeakerName: String?
    private var openSpeaker: OpenSpan?
    private var openCoverage: OpenSpan?
    private var lastObservation: Double?

    private(set) var pollCount = 0
    private(set) var statusCounts: [CallSpeakerSnapshot.Status: Int] = [:]

    init() {}

    mutating func add(_ snapshot: CallSpeakerSnapshot, at time: Double) {
        pollCount += 1
        statusCounts[snapshot.status, default: 0] += 1

        if snapshot.status != .multipleWindows {
            selfNames.formUnion(snapshot.selfNames)
            let rosterIsTrusted = (snapshot.app?.detectsSelf ?? true) || !snapshot.selfNames.isEmpty
            for name in snapshot.roster where rosterIsTrusted && !roster.contains(name) {
                roster.append(name)
            }
        }

        if let last = lastObservation, time - last > Self.maxObservationGap {
            closeAll(at: last)
        }
        // Withheld: no evidence either way.
        guard !snapshot.status.isWithheld else { return }
        lastObservation = time

        if snapshot.status == .speakingIndicator { sawSpeakingIndicator = true }
        let others = snapshot.status == .speakingIndicator ? snapshot.othersSpeaking : []
        guard others.count == 1, let speaker = others.first else {
            closeAll(at: time)
            return
        }
        let shift = snapshot.app?.isTeams == true ? Self.teamsLagSeconds : 0
        if openSpeakerName != nil, openSpeakerName != speaker {
            closeSpeaker(at: time)
        }
        if openCoverage == nil { openCoverage = OpenSpan(start: time, shift: shift) }
        if openSpeaker == nil {
            openSpeakerName = speaker
            openSpeaker = OpenSpan(start: time, shift: shift)
        }
    }

    /// Reading stopped (setting off, Accessibility gone): close what is open
    /// at the last poll, without counting a poll.
    mutating func pause() {
        if let last = lastObservation { closeAll(at: last) }
        lastObservation = nil
    }

    /// The activity so far; open spans end at the last poll.
    func finished() -> CallSpeakerActivity {
        var copy = self
        copy.pause()
        let others = copy.roster.filter { !copy.selfNames.contains($0) }
        return CallSpeakerActivity(
            intervals: copy.intervals,
            coverage: copy.coverage,
            rosterNames: others,
            selfNames: copy.selfNames,
            sawSpeakingIndicator: copy.sawSpeakingIndicator
        )
    }

    private static func shifted(_ span: OpenSpan, end: Double) -> (start: Double, end: Double) {
        (max(0, span.start - span.shift), max(0, end - span.shift))
    }

    private mutating func closeSpeaker(at time: Double) {
        guard let open = openSpeaker, let name = openSpeakerName else { return }
        openSpeaker = nil
        openSpeakerName = nil
        guard time - open.start >= Self.minSpanSeconds else { return }
        let range = Self.shifted(open, end: time)
        intervals.append(.init(name: name, start: range.start, end: range.end))
        if intervals.count > Self.maxSpans { intervals.removeFirst(intervals.count - Self.maxSpans) }
    }

    private mutating func closeAll(at time: Double) {
        closeSpeaker(at: time)
        if let open = openCoverage {
            openCoverage = nil
            let range = Self.shifted(open, end: time)
            if range.end > range.start {
                coverage.append(.init(start: range.start, end: range.end))
                if coverage.count > Self.maxSpans { coverage.removeFirst(coverage.count - Self.maxSpans) }
            }
        }
    }
}

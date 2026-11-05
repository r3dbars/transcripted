// CallSpeakerActivityRecorder.swift
// While a meeting records, polls the call app's meeting window and folds
// what it shows into `CallSpeakerActivity` for the pipeline.
//
// - Cadence (unverified): every 1 s while the call shows a
//   roster, every 3 s otherwise. Three empty polls in a row drop the roster
//   back to the slow cadence.
// - Each poll is timestamped at the midpoint of its read.
// - The read and the parse run off the main actor; only folding the snapshot
//   (a few dictionary writes) runs here.
// - Polls never overlap: the loop awaits each read before scheduling the next.
// - With the preference off, Accessibility not trusted, or no supported app
//   running, it re-checks every 5 s and reads nothing.
// - Time comes from an injected clock, so tests run on virtual time.
//
// Privacy: names stay in memory and go only to the pipeline. The run summary
// carries counts and status enums only.

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// What one read of the supported apps found.
struct CallSpeakerReadResult: Sendable {
    enum Completeness: Sendable, Equatable {
        case complete
        case incomplete
    }

    /// False when no supported call app (or browser) is running.
    var supportedAppRunning: Bool
    var windows: [CallSpeakerWindowRead]
    /// Incomplete scans may have omitted another call. Never name from them.
    var completeness: Completeness
    /// Captured around the actual serialized AX scan, not caller scheduling,
    /// application inventory, parsing, or delivery back to the main actor.
    var timing: CallSpeakerReadTiming? = nil
    /// Why windows were cut short or the scan stopped early. Codes only.
    var diagnostics = CallSpeakerScanDiagnostics()

    static let nothingRunning = CallSpeakerReadResult(supportedAppRunning: false, windows: [], completeness: .complete)
}

/// Reads the meeting windows of the running call apps. `session` changes
/// once per recording, so per-recording setup (Chromium's
/// `AXManualAccessibility`) happens once per app per recording.
protocol CallSpeakerWindowReading: Sendable {
    func read(session: UUID) async -> CallSpeakerReadResult
}

/// Time for the poll loop. Production reads the real clock; tests install a
/// virtual one whose sleeps only move its own time.
struct CallSpeakerPollClock: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant
    var sleep: @Sendable (Duration) async throws -> Void

    static let live = CallSpeakerPollClock(
        now: { ContinuousClock.now },
        sleep: { try await Task.sleep(for: $0) }
    )
}

/// Counts from one recording, safe to log.
struct CallSpeakerRecorderSummary: Equatable, Sendable {
    var polls = 0
    var gatedChecks = 0
    var statusCounts: [CallSpeakerSnapshot.Status: Int] = [:]
    var intervalCount = 0
    var rosterCount = 0
    var sawSpeakingIndicator = false
    /// AX error codes and limits behind truncated windows, incomplete scans
    /// and skipped elements, summed over the recording.
    var scanDiagnostics = CallSpeakerScanDiagnostics()
}

@MainActor
final class CallSpeakerActivityRecorder {
    /// Poll cadence while the call shows a roster.
    static let rosterPollInterval: Double = 1.0
    /// Poll cadence while it doesn't.
    static let idlePollInterval: Double = 3.0
    /// Re-check cadence while reading is off (setting, Accessibility, no app).
    static let gatedRecheckInterval: Double = 5
    /// Empty polls in a row that drop the current roster.
    static let emptyPollsToClearRoster = 3

    struct Environment {
        var isEnabled: @MainActor () -> Bool
        var isAccessibilityTrusted: @MainActor () -> Bool
        var reader: CallSpeakerWindowReading
        var clock: CallSpeakerPollClock
        var hostClock: CallSpeakerHostClock = .live
    }

    private let environment: Environment
    private var task: Task<Void, Never>?
    private var session: UUID?
    private var origin: ContinuousClock.Instant?
    private var originHostTime: UInt64 = 0
    private var accumulator = CallSpeakerActivityAccumulator()
    private var gatedChecks = 0
    private var hasCurrentRoster = false
    private var consecutiveEmptyPolls = 0
    private var scanDiagnostics = CallSpeakerScanDiagnostics()

    /// The recording being watched (the key the pipeline asks with).
    private(set) var recordingStartedAt: Date?
    private(set) var lastSummary: CallSpeakerRecorderSummary?

    var isRunning: Bool { task != nil }

    init(environment: Environment) {
        self.environment = environment
    }

    func start(recordingStartedAt: Date) {
        if task != nil { _ = stop() }
        let session = UUID()
        self.session = session
        self.recordingStartedAt = recordingStartedAt
        origin = environment.clock.now()
        originHostTime = environment.hostClock.now()
        accumulator = CallSpeakerActivityAccumulator()
        gatedChecks = 0
        hasCurrentRoster = false
        consecutiveEmptyPolls = 0
        scanDiagnostics = CallSpeakerScanDiagnostics()
        task = Task { [weak self] in
            await self?.run(session: session)
        }
    }

    /// Stops polling and returns what was seen, or nil when nothing was.
    func stop() -> CallSpeakerObservedActivity? {
        guard let task else { return nil }
        task.cancel()
        self.task = nil
        session = nil
        let activity = accumulator.finished()
        lastSummary = CallSpeakerRecorderSummary(
            polls: accumulator.pollCount,
            gatedChecks: gatedChecks,
            statusCounts: accumulator.statusCounts,
            intervalCount: activity.intervals.count,
            rosterCount: activity.rosterNames.count,
            sawSpeakingIndicator: activity.sawSpeakingIndicator,
            scanDiagnostics: scanDiagnostics
        )
        guard !activity.isEmpty || activity.sawSpeakingIndicator || !activity.selfNames.isEmpty else { return nil }
        return CallSpeakerObservedActivity(
            originHostTime: originHostTime,
            ticksPerSecond: environment.hostClock.ticksPerSecond,
            relativeActivity: activity
        )
    }

    private func elapsed() -> Double {
        guard let origin else { return 0 }
        let parts = (environment.clock.now() - origin).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func isCurrent(_ session: UUID) -> Bool {
        !Task.isCancelled && self.session == session
    }

    private func sleep(seconds: Double) async -> Bool {
        guard seconds > 0 else { return true }
        do {
            try await environment.clock.sleep(.milliseconds(Int64((seconds * 1000).rounded(.up))))
            return true
        } catch {
            return false
        }
    }

    private func noteRoster(_ snapshot: CallSpeakerSnapshot) {
        if snapshot.roster.isEmpty && snapshot.selfNames.isEmpty {
            consecutiveEmptyPolls += 1
            if consecutiveEmptyPolls >= Self.emptyPollsToClearRoster { hasCurrentRoster = false }
        } else {
            consecutiveEmptyPolls = 0
            hasCurrentRoster = true
        }
    }

    private func run(session: UUID) async {
        while isCurrent(session) {
            if !environment.isEnabled() || !environment.isAccessibilityTrusted() {
                gatedChecks += 1
                accumulator.pause()
                guard await sleep(seconds: Self.gatedRecheckInterval) else { return }
                continue
            }

            let reader = environment.reader
            let readStart = elapsed()
            let result = await Task.detached(priority: .utility) { () -> (Bool, CallSpeakerSnapshot, CallSpeakerReadTiming?, CallSpeakerScanDiagnostics) in
                let read = await reader.read(session: session)
                guard read.supportedAppRunning else { return (false, .empty(.noWindow), read.timing, read.diagnostics) }
                return (true, CallSpeakerSnapshotBuilder.build(read), read.timing, read.diagnostics)
            }.value
            guard isCurrent(session) else { return }
            scanDiagnostics.merge(result.3)

            guard result.0 else {
                accumulator.pause()
                guard await sleep(seconds: Self.gatedRecheckInterval) else { return }
                continue
            }
            guard let midpoint = result.2?.midpoint, midpoint >= originHostTime,
                  environment.hostClock.ticksPerSecond.isFinite,
                  environment.hostClock.ticksPerSecond > 0 else {
                accumulator.pause()
                guard await sleep(seconds: Self.gatedRecheckInterval) else { return }
                continue
            }
            let observedSeconds = Double(midpoint - originHostTime) / environment.hostClock.ticksPerSecond
            accumulator.add(result.1, at: observedSeconds)
            noteRoster(result.1)

            let interval = hasCurrentRoster ? Self.rosterPollInterval : Self.idlePollInterval
            guard await sleep(seconds: readStart + interval - elapsed()) else { return }
        }
    }
}


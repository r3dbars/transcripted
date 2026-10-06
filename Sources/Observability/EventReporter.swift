// EventReporter.swift
// Centralized event tracking — structured JSONL for local diagnostics + optional Sentry forwarding.
//
// Design: @MainActor singleton + actor-based file writer (same pattern as AppLogSink).
// Fire-and-forget via Task.detached — capture() never blocks the caller.

import Foundation

// MARK: - EventReporter Singleton

@MainActor
final class EventReporter {
    static let shared = EventReporter()

    private let writer = EventFileWriter()
    private var engineStateSummary: (() -> [String: String])?
    private var pendingAppendTasks: [Int: Task<Void, Never>] = [:]
    private var nextAppendTaskID = 0

    private let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }()

    private let osVersion: String = {
        ProcessInfo.processInfo.operatingSystemVersionString
    }()

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {}

    /// Register a closure that provides live engine state for context enrichment.
    /// Called by TranscriptedAppState.initialize() after all engines are wired.
    func setEngineStateSummary(_ provider: @escaping () -> [String: String]) {
        engineStateSummary = provider
    }

    /// Capture an event. Fire-and-forget — never blocks the caller.
    /// `forwardToSentry: false` keeps an allowlisted `.error` out of Sentry
    /// for this one call; everything else (local log, reliability packet,
    /// `reliability_failure_observed`) is unchanged.
    func capture(
        level: EventLevel,
        engine: String,
        event: String,
        message: String,
        context: [String: String]? = nil,
        forwardToSentry: Bool = true
    ) {
        let plan = ObservabilityEventCapturePlan.make(
            level: level,
            engine: engine,
            event: event,
            message: message,
            context: context,
            engineState: engineStateSummary?(),
            infoDictionary: Bundle.main.infoDictionary,
            timestamp: isoFormatter.string(from: Date()),
            appVersion: appVersion,
            osVersion: osVersion,
            forwardToSentry: forwardToSentry
        )
        let localEntry = plan.localEntry

        let appendTaskID = nextAppendTaskID
        nextAppendTaskID += 1
        let appendTask = Task.detached(priority: .utility) { [writer, localEntry] in
            await writer.append(localEntry)
            await MainActor.run {
                EventReporter.shared.markAppendTaskFinished(appendTaskID)
            }
        }
        pendingAppendTasks[appendTaskID] = appendTask
        // Hand the recorder the raw entry, not `localEntry`. The recorder
        // positive-allowlists every key and text-redacts every value itself;
        // feeding it the substring-blanked copy shipped the literal
        // "[redacted-sensitive-value]" for `input_device_class` in support
        // bundles and blanked the `audio_gaps` / `device_switches` /
        // `system_file_present` inputs its outcome derivation reads, so the
        // `recovered` outcome and `system_stream_present=true` were unreachable.
        ReliabilityPacketRecorder.record(event: plan.entry)

        if let forwarded = plan.forwarded {
            AnalyticsReporter.track(forwarded.name, properties: forwarded.properties)
        }

        if let sentryPolicy = plan.sentryPolicy {
            // One canonical analytics counterpart for every allowlisted hard failure,
            // including low-level engine failures without a product lifecycle event.
            // Both sinks receive the exact same UUIDs and failure taxonomy.
            AnalyticsReporter.track("reliability_failure_observed", properties: plan.mergedContext)
            if plan.forwardsToSentry {
                CrashReporter.shared.captureObservabilityEvent(
                    level: level,
                    engine: sentryPolicy.engine,
                    event: sentryPolicy.event,
                    message: sentryPolicy.summary,
                    context: plan.mergedContext
                )
            }
        }
    }

    func flushLocalEventsForShutdown() async {
        await LocalEventShutdownFlush.run(
            flushEvents: {
                while !self.pendingAppendTasks.isEmpty {
                    let tasks = Array(self.pendingAppendTasks.values)
                    self.pendingAppendTasks.removeAll(keepingCapacity: true)
                    for task in tasks {
                        await task.value
                    }
                }
                await self.writer.flushForShutdown()
            },
            flushPackets: { await ReliabilityPacketRecorder.flushForShutdown() }
        )
    }

    private func markAppendTaskFinished(_ id: Int) {
        pendingAppendTasks[id] = nil
    }
}

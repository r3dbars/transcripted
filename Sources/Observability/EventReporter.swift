// EventReporter.swift
// Centralized event tracking — structured JSONL for local diagnostics + optional Sentry forwarding.
//
// Design: @MainActor singleton + actor-based file writer (same pattern as AppLogSink).
// Fire-and-forget via Task.detached — capture() never blocks the caller.

import Foundation

// MARK: - Event Schema

enum EventLevel: String, Codable {
    case error
    case warning
    case info
}

// MARK: - File Writer (Actor)

private actor EventFileWriter {
    private let fileURL: URL
    private var handle: FileHandle?
    private var isPrepared = false
    private var approximateSize: UInt64 = 0
    private var bufferedInfoEventLines: [Data] = []
    private var infoFlushTask: Task<Void, Never>?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []  // Compact — one record per line
        return e
    }()

    init() {
        let storageDir = FileManager.default.transcriptedLogsDirURL
        fileURL = storageDir.appendingPathComponent("events.jsonl")
    }

    func append(_ event: ObservabilityEvent) {
        guard let lineData = lineData(for: event) else { return }
        guard prepareIfNeeded() else { return }

        if EventFileWritePolicy.shouldBuffer(level: event.level) {
            bufferedInfoEventLines.append(lineData)
            if EventFileWritePolicy.shouldFlushBufferedInfoEvents(count: bufferedInfoEventLines.count) {
                flushBufferedInfoEvents()
            } else {
                scheduleInfoFlush()
            }
            return
        }

        flushBufferedInfoEvents()
        write(lineData)
    }

    func flushForShutdown() {
        guard prepareIfNeeded() else { return }
        flushBufferedInfoEvents()
        try? handle?.synchronize()
    }

    private func lineData(for event: ObservabilityEvent) -> Data? {
        let data: Data
        do {
            data = try encoder.encode(event)
        } catch {
            fputs("⚠️ EVENT | failed to encode event '\(event.event)': \(error.localizedDescription)\n", stderr)
            return nil
        }

        var lineData = data
        lineData.append(0x0A)
        return lineData
    }

    private func scheduleInfoFlush() {
        guard infoFlushTask == nil else { return }
        let delay = EventFileWritePolicy.infoFlushDelayNanoseconds
        infoFlushTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            self.flushBufferedInfoEvents()
        }
    }

    private func flushBufferedInfoEvents() {
        guard !bufferedInfoEventLines.isEmpty else { return }

        let task = infoFlushTask
        infoFlushTask = nil
        task?.cancel()

        let payload = bufferedInfoEventLines.reduce(into: Data()) { partial, line in
            partial.append(line)
        }
        bufferedInfoEventLines.removeAll(keepingCapacity: true)
        write(payload)
    }

    private func write(_ lineData: Data) {
        if handle == nil {
            // A rotation earlier in this same append cycle (the info-buffer
            // flush crossing the threshold) closes the handle; reopen here so
            // the warning/error event that triggered the flush is not lost.
            guard prepareIfNeeded() else { return }
        }
        if let handle {
            LockedFileAppender.append(lineData, to: handle)
            approximateSize += UInt64(lineData.count)
            if approximateSize > TranscriptedConstants.jsonlLogRotationThreshold {
                // Close so the next write re-prepares, which rotates the file.
                try? handle.close()
                self.handle = nil
                isPrepared = false
            }
        }
    }

    private func prepareIfNeeded() -> Bool {
        guard !isPrepared else { return true }

        guard let prepared = ObservabilityLogFilePreparation.openPreparedHandle(
            at: fileURL,
            onDirectoryError: { fputs("⚠️ EVENT | failed to create local event directory: \($0)\n", stderr) },
            onRotated: { fputs("📊 EVENT | rotated events.jsonl\n", stderr) },
            onCreated: { fputs("📊 EVENT | created events.jsonl\n", stderr) },
            onOpenError: { fputs("⚠️ EVENT | failed to open local event log: \($0)\n", stderr) }
        ) else {
            return false
        }

        do {
            handle = prepared
            // seekToEnd() (error-returning) instead of the legacy seekToEndOfFile(),
            // which raises an uncatchable ObjC NSException on failure. Any error here
            // is caught below and treated as a failed prepare rather than a crash.
            approximateSize = try prepared.seekToEnd()
            isPrepared = true
            return true
        } catch {
            fputs("⚠️ EVENT | failed to open local event log: \(ObservabilityTextRedactor.redact(error.localizedDescription))\n", stderr)
            try? prepared.close()
            handle = nil
            return false
        }
    }

    deinit {
        if let handle, !bufferedInfoEventLines.isEmpty {
            let payload = bufferedInfoEventLines.reduce(into: Data()) { partial, line in
                partial.append(line)
            }
            LockedFileAppender.append(payload, to: handle)
        }
        infoFlushTask?.cancel()
        try? handle?.close()
    }
}

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
    func capture(
        level: EventLevel,
        engine: String,
        event: String,
        message: String,
        context: [String: String]? = nil
    ) {
        // Merge caller context with live engine state
        var mergedContext = context ?? [:]
        if let stateSnapshot = engineStateSummary?() {
            for (key, value) in stateSnapshot where mergedContext[key] == nil {
                mergedContext[key] = value
            }
        }
        let infoDictionary = Bundle.main.infoDictionary
        if mergedContext["build_version"] == nil {
            mergedContext["build_version"] = infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        }
        if mergedContext["build_channel"] == nil {
            mergedContext["build_channel"] = AnalyticsRuntimeConfiguration.buildChannel(infoDictionary: infoDictionary)
        }
        if mergedContext["build_revision"] == nil {
            mergedContext["build_revision"] = AnalyticsRuntimeConfiguration.buildRevision(infoDictionary: infoDictionary)
        }

        let entry = ObservabilityEvent(
            timestamp: isoFormatter.string(from: Date()),
            level: level.rawValue,
            engine: engine,
            event: event,
            message: message,
            context: mergedContext.isEmpty ? nil : mergedContext,
            appVersion: appVersion,
            osVersion: osVersion
        )
        let localEntry = LocalObservabilityPayloadSanitizer.sanitize(entry)

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
        ReliabilityPacketRecorder.record(event: entry)

        if level == .error,
           let sentryPolicy = SentryEventPolicy.policy(forEngine: engine, event: event) {
            CrashReporter.shared.captureObservabilityEvent(
                level: level,
                engine: sentryPolicy.engine,
                event: sentryPolicy.event,
                message: sentryPolicy.summary,
                context: mergedContext
            )
        }
    }

    func flushLocalEventsForShutdown() async {
        while !pendingAppendTasks.isEmpty {
            let tasks = Array(pendingAppendTasks.values)
            pendingAppendTasks.removeAll(keepingCapacity: true)
            for task in tasks {
                await task.value
            }
        }
        await writer.flushForShutdown()
        await ReliabilityPacketRecorder.flushForShutdown()
    }

    private func markAppendTaskFinished(_ id: Int) {
        pendingAppendTasks[id] = nil
    }
}

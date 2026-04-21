// EventReporter.swift
// Centralized event tracking — structured JSONL for local diagnostics + optional Sentry forwarding.
//
// Design: @MainActor singleton + actor-based file writer (same pattern as AppLogger).
// Fire-and-forget via Task.detached — capture() never blocks the caller.

import Foundation

// MARK: - Event Schema

enum EventLevel: String, Codable {
    case error
    case warning
    case info
}

struct ObservabilityEvent: Codable {
    let timestamp: String
    let level: String
    let engine: String
    let event: String
    let message: String
    let context: [String: String]?
    let appVersion: String
    let osVersion: String
}

// MARK: - File Writer (Actor)

private actor EventFileWriter {
    private let fileURL: URL
    private var handle: FileHandle?
    private var isPrepared = false
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
        let data: Data
        do {
            data = try encoder.encode(event)
        } catch {
            fputs("⚠️ EVENT | failed to encode event '\(event.event)': \(error.localizedDescription)\n", stderr)
            return
        }

        guard prepareIfNeeded() else { return }

        var lineData = data
        lineData.append(0x0A)
        handle?.write(lineData)
    }

    private func prepareIfNeeded() -> Bool {
        guard !isPrepared else { return true }

        let storageDir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createPrivateDirectory(at: storageDir)
        } catch {
            fputs("⚠️ EVENT | failed to create directory \(storageDir.path): \(error.localizedDescription)\n", stderr)
            return false
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            FileManager.default.restrictFileToOwnerOnly(at: fileURL)
            print("📊 EVENT | created events.jsonl at \(fileURL.path)")
        }

        do {
            handle = try FileHandle(forWritingTo: fileURL)
            handle?.seekToEndOfFile()
            isPrepared = true
            return true
        } catch {
            fputs("⚠️ EVENT | failed to open FileHandle for \(fileURL.path): \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    deinit {
        try? handle?.close()
    }
}

// MARK: - EventReporter Singleton

@MainActor
final class EventReporter {
    static let shared = EventReporter()

    private let writer = EventFileWriter()
    private var engineStateSummary: (() -> [String: String])?

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

        Task.detached(priority: .utility) { [writer, entry] in
            await writer.append(entry)
        }

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
}

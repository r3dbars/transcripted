// EventReporter.swift
// Centralized event tracking — structured JSONL for Claude Code + optional Sentry forwarding
//
// Every meaningful error, warning, and operational event across all engines funnels through
// EventReporter.shared.capture(). Events are written to ~/Library/Application Support/Draft/events.jsonl
// (same directory as feedback.jsonl and prompts.json) and optionally forwarded to Sentry.
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
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []  // Compact — one record per line
        return e
    }()

    init() {
        let storageDir = FileManager.default.draftAppSupportDir
        fileURL = storageDir.appendingPathComponent("events.jsonl")

        // Ensure directory exists
        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        } catch {
            print("⚠️ EVENT | failed to create directory \(storageDir.path): \(error.localizedDescription)")
        }
    }

    func append(_ event: ObservabilityEvent) {
        guard let data = try? encoder.encode(event),
              let line = String(data: data, encoding: .utf8) else {
            print("⚠️ EVENT | failed to encode event: \(event.event)")
            return
        }

        let lineData = (line + "\n").data(using: .utf8) ?? Data()

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if handle == nil {
                handle = try? FileHandle(forWritingTo: fileURL)
            }
            if handle == nil {
                print("⚠️ EVENT | failed to open FileHandle for \(fileURL.path)")
            }
            handle?.seekToEndOfFile()
            handle?.write(lineData)
        } else {
            do {
                try lineData.write(to: fileURL)
                print("📊 EVENT | created events.jsonl at \(fileURL.path)")
            } catch {
                print("⚠️ EVENT | failed to create events.jsonl: \(error.localizedDescription)")
            }
            handle = try? FileHandle(forWritingTo: fileURL)
        }
    }

    deinit {
        try? handle?.close()
    }
}

// MARK: - Sentry Transport (Optional)

// TODO(human): Implement Sentry DSN parsing and HTTP transport
private struct SentryTransport {
    func send(_ event: ObservabilityEvent) {
        // No-op until Sentry DSN is configured
    }
}

// MARK: - EventReporter Singleton

@MainActor
final class EventReporter {
    static let shared = EventReporter()

    private let writer = EventFileWriter()
    private let sentry = SentryTransport()
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
    /// Called by DraftAppState.initialize() after all engines are wired.
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

        Task.detached(priority: .utility) { [writer, sentry, entry] in
            await writer.append(entry)
            if entry.level == EventLevel.error.rawValue {
                sentry.send(entry)
            }
        }
    }
}

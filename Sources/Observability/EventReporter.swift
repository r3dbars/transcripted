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
        let storageDir = FileManager.default.transcriptedAppSupportDir
        fileURL = storageDir.appendingPathComponent("events.jsonl")

        // Ensure directory exists
        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        } catch {
            fputs("⚠️ EVENT | failed to create directory \(storageDir.path): \(error.localizedDescription)\n", stderr)
        }
    }

    func append(_ event: ObservabilityEvent) {
        let data: Data
        do {
            data = try encoder.encode(event)
        } catch {
            fputs("⚠️ EVENT | failed to encode event '\(event.event)': \(error.localizedDescription)\n", stderr)
            return
        }
        guard let line = String(data: data, encoding: .utf8) else {
            fputs("⚠️ EVENT | failed to convert encoded data to UTF-8 for event: \(event.event)\n", stderr)
            return
        }

        let lineData = (line + "\n").data(using: .utf8) ?? Data()

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if handle == nil {
                do {
                    handle = try FileHandle(forWritingTo: fileURL)
                } catch {
                    fputs("⚠️ EVENT | failed to open FileHandle for \(fileURL.path): \(error.localizedDescription)\n", stderr)
                }
            }
            handle?.seekToEndOfFile()
            handle?.write(lineData)
        } else {
            do {
                try lineData.write(to: fileURL)
                print("📊 EVENT | created events.jsonl at \(fileURL.path)")
            } catch {
                fputs("⚠️ EVENT | failed to create events.jsonl: \(error.localizedDescription)\n", stderr)
            }
            do {
                handle = try FileHandle(forWritingTo: fileURL)
            } catch {
                fputs("⚠️ EVENT | failed to open FileHandle after creation: \(error.localizedDescription)\n", stderr)
            }
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
    }
}

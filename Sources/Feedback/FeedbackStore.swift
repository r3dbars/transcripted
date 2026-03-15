// FeedbackStore.swift
// Logs every accepted draft to ~/Library/Application Support/Draft/feedback.jsonl
//
// WHY: The AnalysisEngine reads this file to understand which drafts the user
// accepted, edited, or rejected. It uses these signals to rewrite prompts.json and
// improve drafting quality over time. Each line is a self-contained JSON record.
//
// SCHEMA (one JSON object per line):
// {
//   "timestamp": "2026-02-17T16:30:00Z",
//   "raw_text": "user's spoken/typed input",
//   "drafted_text": "what the model produced",
//   "accepted_text": "what was actually copied/pasted (may differ if user edited)",
//   "action": "copy" | "paste",
//   "example_count": 5
// }

import Foundation

enum AcceptAction: String, Codable {
    case copy
    case paste
}

struct FeedbackEntry: Codable {
    let timestamp: String
    let rawText: String
    let draftedText: String      // Original AI output
    let acceptedText: String     // What user actually sent (edited or identical)
    let action: AcceptAction
    let exampleCount: Int        // Style examples at time of accept
    let formality: String?       // Detected register: casual/professional/formal (from vision)

    enum CodingKeys: String, CodingKey {
        case timestamp
        case rawText = "raw_text"
        case draftedText = "drafted_text"
        case acceptedText = "accepted_text"
        case action
        case exampleCount = "example_count"
        case formality
    }
}

struct UsageStats {
    var wordsDictated: Int = 0
    var messagesDrafted: Int = 0
    var minutesSaved: Int = 0
    var wordsDrafted: Int = 0
    var wordsAccepted: Int = 0
}

@MainActor
class FeedbackStore: ObservableObject {
    @Published var stats = UsageStats()

    private let feedbackURL: URL
    private let encoder: JSONEncoder
    private let isoFormatter: ISO8601DateFormatter
    private let writer: JSONLWriter
    private var lastStatsModDate: Date?

    init() {
        let storageDir = FileManager.default.draftAppSupportDir
        feedbackURL = storageDir.appendingPathComponent("feedback.jsonl")

        encoder = JSONEncoder()
        encoder.outputFormatting = []  // Compact — one record per line

        isoFormatter = ISO8601DateFormatter()
        writer = JSONLWriter(fileURL: feedbackURL)
    }

    /// Record a user acceptance signal. Call this whenever Copy or Paste is triggered.
    func record(
        rawText: String,
        draftedText: String,
        acceptedText: String,
        action: AcceptAction,
        exampleCount: Int,
        formality: String? = nil
    ) {
        let entry = FeedbackEntry(
            timestamp: isoFormatter.string(from: Date()),
            rawText: rawText,
            draftedText: draftedText,
            acceptedText: acceptedText,
            action: action,
            exampleCount: exampleCount,
            formality: formality
        )

        guard let data = try? encoder.encode(entry) else {
            EventReporter.shared.capture(level: .error, engine: "feedback", event: "feedback_encode_failed",
                message: "Failed to JSON-encode feedback entry")
            return
        }

        let w = writer
        Task { await w.append(data) }
    }

    /// Parse feedback.jsonl and compute aggregate usage stats.
    /// Skips reparsing if the file hasn't been modified since the last call.
    /// File I/O runs on a background thread to avoid blocking the main actor.
    func refreshStats() {
        let url = feedbackURL
        // Check modification date — skip expensive reparse if file hasn't changed
        let currentModDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let currentModDate, let lastModDate = lastStatsModDate, currentModDate == lastModDate {
            return  // File unchanged since last parse
        }
        let captured = currentModDate
        Task {
            let computed = await Task.detached {
                FeedbackStore.parseStats(url: url)
            }.value
            self.stats = computed
            self.lastStatsModDate = captured
        }
    }

    /// Pure computation: read and parse feedback.jsonl (runs off main actor).
    nonisolated private static func parseStats(url: URL) -> UsageStats {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return UsageStats()
        }

        let decoder = JSONDecoder()
        var wordsDictated = 0
        var wordsDrafted = 0
        var wordsAccepted = 0
        var messageCount = 0

        for line in content.split(separator: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(FeedbackEntry.self, from: lineData) else {
                continue
            }
            messageCount += 1
            wordsDictated += entry.rawText.split(separator: " ").count
            wordsDrafted += entry.draftedText.split(separator: " ").count
            wordsAccepted += entry.acceptedText.split(separator: " ").count
        }

        return UsageStats(
            wordsDictated: wordsDictated,
            messagesDrafted: messageCount,
            minutesSaved: (wordsDrafted + wordsAccepted) / 40,
            wordsDrafted: wordsDrafted,
            wordsAccepted: wordsAccepted
        )
    }
}

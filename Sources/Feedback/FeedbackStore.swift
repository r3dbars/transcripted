// FeedbackStore.swift
// Logs every accepted draft to ~/Library/Application Support/Draft/feedback.jsonl
//
// WHY: The orchestrator agent reads this file to understand which drafts the user
// accepted, edited, or rejected. It uses these signals to rewrite prompts.json and
// improve drafting quality over time. Each line is a self-contained JSON record.
//
// SCHEMA (one JSON object per line):
// {
//   "timestamp": "2026-02-17T16:30:00Z",
//   "raw_text": "user's spoken/typed input",
//   "drafted_text": "what Claude produced",
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
    let draftedText: String      // Original Claude output
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

class FeedbackStore: ObservableObject {
    private let feedbackURL: URL
    private let encoder: JSONEncoder
    private let isoFormatter: ISO8601DateFormatter

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let storageDir = appSupport.appendingPathComponent("Draft", isDirectory: true)
        feedbackURL = storageDir.appendingPathComponent("feedback.jsonl")

        encoder = JSONEncoder()
        encoder.outputFormatting = []  // Compact — one record per line

        isoFormatter = ISO8601DateFormatter()
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

        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }

        let lineWithNewline = (line + "\n").data(using: .utf8) ?? Data()

        if FileManager.default.fileExists(atPath: feedbackURL.path) {
            guard let handle = try? FileHandle(forWritingTo: feedbackURL) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(lineWithNewline)
        } else {
            try? lineWithNewline.write(to: feedbackURL)
        }
    }

}

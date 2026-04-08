import Foundation
@testable import transcripted_mcp

func makeFixtureJSON(
    date: String = "2026-03-29T10:00:00-0500",
    durationSeconds: Int = 1800,
    speakers: [(id: String, name: String, persistentId: String?)] = [
        ("mic_0", "You", nil),
        ("system_0", "Jenny Wen", "80FB272B-6061-4FC4-8408-3F7A974C59DB")
    ],
    utterances: [(speakerId: String, start: Double, end: Double, text: String)] = [
        ("mic_0", 0.0, 5.0, "Good morning everyone"),
        ("system_0", 5.0, 10.0, "Let's discuss the product roadmap"),
    ]
) -> Data {
    let agentSpeakers = speakers.map { s in
        [
            "id": s.id,
            "persistent_speaker_id": s.persistentId as Any,
            "name": s.name,
            "confidence": "high" as Any,
            "word_count": 100,
            "speaking_seconds": 60.0
        ] as [String: Any]
    }

    let agentUtterances = utterances.map { u in
        [
            "start": u.start,
            "end": u.end,
            "speaker_id": u.speakerId,
            "text": u.text
        ] as [String: Any]
    }

    let json: [String: Any] = [
        "version": "1.0",
        "recording": [
            "date": date,
            "duration_seconds": durationSeconds,
            "dropped_segments": 0,
            "engines": [
                "stt": "parakeet-tdt-v3",
                "diarization": "pyannote-offline"
            ]
        ],
        "speakers": agentSpeakers,
        "utterances": agentUtterances
    ]

    return try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
}

func writeFixture(_ data: Data, filename: String, to directory: URL) throws {
    let path = directory.appendingPathComponent("\(filename).json")
    try data.write(to: path)
}

func makeDictationDayJSON(
    date: String = "2026-04-07",
    markdownFilename: String = "Dictations_2026-04-07.md",
    entries: [(id: String, createdAt: String, title: String, text: String, sourceAppName: String, delivery: String)] = [
        ("dictation-20260407-091500-000", "2026-04-07T09:15:00-0500", "Morning note", "Ship the follow-up note to product today", "Slack", "copied"),
        ("dictation-20260407-183000-000", "2026-04-07T18:30:00-0500", "Evening note", "Remember to send the recap before dinner", "Mail", "pasted"),
    ]
) -> Data {
    let dictationEntries = entries.map { entry in
        [
            "id": entry.id,
            "created_at": entry.createdAt,
            "title": entry.title,
            "text": entry.text,
            "source_app_name": entry.sourceAppName,
            "source_app_bundle_id": "com.example.\(entry.sourceAppName.lowercased())",
            "delivery": entry.delivery,
            "word_count": entry.text.split(whereSeparator: \.isWhitespace).count,
            "character_count": entry.text.count
        ] as [String: Any]
    }

    let json: [String: Any] = [
        "version": "1.0",
        "capture_type": "dictation_day",
        "date": date,
        "markdown_filename": markdownFilename,
        "entry_count": dictationEntries.count,
        "word_count": dictationEntries.reduce(0) { partialResult, item in
            partialResult + ((item["word_count"] as? Int) ?? 0)
        },
        "entries": dictationEntries
    ]

    return try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
}

func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func removeTempDir(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

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

func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func removeTempDir(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

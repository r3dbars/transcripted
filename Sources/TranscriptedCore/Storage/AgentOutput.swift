import Foundation

// MARK: - Agent Output JSON Types

/// Top-level JSON structure for a single transcript sidecar.
/// Designed for AI agent consumption — flat, unambiguous, chronological.
struct AgentTranscript: Codable {
    let version: String
    let transcriptId: String?
    let recording: AgentRecording
    let speakers: [AgentSpeaker]
    let utterances: [AgentUtterance]

    enum CodingKeys: String, CodingKey {
        case version
        case transcriptId = "transcript_id"
        case recording
        case speakers
        case utterances
    }
}

struct AgentRecording: Codable {
    let date: String              // ISO 8601
    let durationSeconds: Int
    let droppedSegments: Int
    let engines: AgentEngines

    enum CodingKeys: String, CodingKey {
        case date
        case durationSeconds = "duration_seconds"
        case droppedSegments = "dropped_segments"
        case engines
    }
}

struct AgentEngines: Codable {
    let stt: String
    let diarization: String
}

struct AgentSpeaker: Codable {
    let id: String
    let persistentSpeakerId: String?
    let name: String
    let confidence: String?
    let wordCount: Int
    let speakingSeconds: Double

    enum CodingKeys: String, CodingKey {
        case id
        case persistentSpeakerId = "persistent_speaker_id"
        case name
        case confidence
        case wordCount = "word_count"
        case speakingSeconds = "speaking_seconds"
    }
}

struct AgentUtterance: Codable {
    let start: Double
    let end: Double
    let speakerId: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case start, end
        case speakerId = "speaker_id"
        case text
    }
}

// MARK: - Index File Types

struct AgentIndex: Codable {
    let version: String
    let updatedAt: String
    let transcriptCount: Int
    let transcripts: [AgentIndexEntry]
    let knownSpeakers: [AgentKnownSpeaker]

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case transcriptCount = "transcript_count"
        case transcripts
        case knownSpeakers = "known_speakers"
    }
}

struct AgentIndexEntry: Codable {
    let filename: String
    let date: String
    let durationSeconds: Int
    let speakerCount: Int
    let wordCount: Int
    let speakers: [String]

    enum CodingKeys: String, CodingKey {
        case filename, date
        case durationSeconds = "duration_seconds"
        case speakerCount = "speaker_count"
        case wordCount = "word_count"
        case speakers
    }
}

struct AgentKnownSpeaker: Codable {
    let persistentId: String
    let name: String
    let callCount: Int

    enum CodingKeys: String, CodingKey {
        case persistentId = "persistent_id"
        case name
        case callCount = "call_count"
    }
}

// MARK: - Agent Output Writer

public enum AgentOutput {

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    /// Write a structured JSON sidecar for a transcript.
    public static func writeTranscriptJSON(
        from result: TranscriptionResult,
        transcriptId: UUID,
        speakerMappings: [String: SpeakerMapping],
        speakerDbIds: [String: UUID],
        to folder: URL,
        stem: String
    ) throws {
        let dateString = isoDateFormatter.string(from: Date())

        // Build speaker list
        var speakers: [AgentSpeaker] = []

        // Mic speaker(s)
        let micSpeakerIds = Set(result.micUtterances.map { $0.speakerId })
        for micId in micSpeakerIds.sorted() {
            let key = "mic_\(micId)"
            let name = speakerMappings[key]?.displayName ?? "You"
            let utterances = result.micUtterances.filter { $0.speakerId == micId }
            let wordCount = utterances.reduce(0) { $0 + $1.transcript.split(separator: " ").count }
            let speakingTime = utterances.reduce(0.0) { $0 + ($1.end - $1.start) }

            speakers.append(AgentSpeaker(
                id: "mic_\(micId)",
                persistentSpeakerId: nil,
                name: name,
                confidence: nil,
                wordCount: wordCount,
                speakingSeconds: (speakingTime * 10).rounded() / 10
            ))
        }

        // System speakers
        let systemSpeakerIds = Set(result.systemUtterances.map { $0.speakerId })
        for sysId in systemSpeakerIds.sorted() {
            let key = "system_\(sysId)"
            let mapping = speakerMappings[key]
            let name = mapping?.displayName ?? "Speaker \(sysId)"
            let utterances = result.systemUtterances.filter { $0.speakerId == sysId }
            let wordCount = utterances.reduce(0) { $0 + $1.transcript.split(separator: " ").count }
            let speakingTime = utterances.reduce(0.0) { $0 + ($1.end - $1.start) }
            let persistentId = speakerDbIds[String(sysId)]

            speakers.append(AgentSpeaker(
                id: "system_\(sysId)",
                persistentSpeakerId: persistentId?.uuidString,
                name: name,
                confidence: mapping?.confidence?.rawValue,
                wordCount: wordCount,
                speakingSeconds: (speakingTime * 10).rounded() / 10
            ))
        }

        // Build chronological utterances
        let utterances = result.allUtterances.map { u in
            let speakerId = u.channel == 0 ? "mic_\(u.speakerId)" : "system_\(u.speakerId)"
            return AgentUtterance(start: u.start, end: u.end, speakerId: speakerId, text: u.transcript)
        }

        let transcript = AgentTranscript(
            version: "1.0",
            transcriptId: transcriptId.uuidString,
            recording: AgentRecording(
                date: dateString,
                durationSeconds: Int(result.duration),
                droppedSegments: result.droppedSegments,
                engines: AgentEngines(stt: "parakeet-tdt-v3", diarization: "pyannote-offline")
            ),
            speakers: speakers,
            utterances: utterances
        )

        let data = try encoder.encode(transcript)
        let fileURL = folder.appendingPathComponent("\(stem).json")
        try data.write(to: fileURL, options: .atomic)
        FileManager.default.restrictToOwnerOnly(atPath: fileURL.path)

        AppLogger.pipeline.info("Agent JSON sidecar written", ["file": fileURL.lastPathComponent])
    }

    /// Rebuild the root index file by scanning existing JSON sidecars.
    public static func writeIndex(to folder: URL, speakerStore: any SpeakerStore) throws {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.pathExtension == "json" && $0.lastPathComponent != "transcripted.json" && $0.lastPathComponent != "failed_transcriptions.json" }) else {
            return
        }

        let decoder = JSONDecoder()
        var entries: [AgentIndexEntry] = []

        for file in files.sorted(by: { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }) {
            guard let data = try? Data(contentsOf: file),
                  let transcript = try? decoder.decode(AgentTranscript.self, from: data) else { continue }

            let isoDate = String(transcript.recording.date.prefix(10))
            let totalWords = transcript.speakers.reduce(0) { $0 + $1.wordCount }
            let speakerNames = transcript.speakers.map { $0.name }

            entries.append(AgentIndexEntry(
                filename: file.deletingPathExtension().lastPathComponent,
                date: isoDate,
                durationSeconds: transcript.recording.durationSeconds,
                speakerCount: transcript.speakers.count,
                wordCount: totalWords,
                speakers: speakerNames
            ))
        }

        // Known speakers from database
        let allSpeakers = speakerStore.allSpeakers()
        let knownSpeakers = allSpeakers.compactMap { profile -> AgentKnownSpeaker? in
            guard let name = profile.displayName else { return nil }
            return AgentKnownSpeaker(
                persistentId: profile.id.uuidString,
                name: name,
                callCount: profile.callCount
            )
        }.sorted { $0.callCount > $1.callCount }

        let index = AgentIndex(
            version: "1.0",
            updatedAt: isoDateFormatter.string(from: Date()),
            transcriptCount: entries.count,
            transcripts: entries,
            knownSpeakers: knownSpeakers
        )

        let data = try encoder.encode(index)
        let indexURL = folder.appendingPathComponent("transcripted.json")
        try data.write(to: indexURL, options: .atomic)
        FileManager.default.restrictToOwnerOnly(atPath: indexURL.path)

        AppLogger.pipeline.info("Agent index written", ["transcripts": "\(entries.count)", "speakers": "\(knownSpeakers.count)"])
    }

    /// Content shared by both CLAUDE.md and AGENT.md in the output directory.
    private static let agentReadmeContent = """
    # Transcripted Meeting Data

    Transcripted records, transcribes, and diarizes voice conversations locally on macOS.
    This directory contains local Markdown meeting transcripts for AI agents to read.

    ## File Structure

    | File | Purpose |
    |------|---------|
    | `Call_*.md` | Markdown transcript with YAML metadata, speaker analytics, and the full transcript |

    ## Markdown Layout

    Each meeting file usually includes:

    - YAML frontmatter with date, time, duration, engine, source, and speaker metadata
    - A channel and speaker analytics section
    - A full timestamped transcript

    ### Speaker Tracking

    - Each speaker has an `id` (e.g., `mic_0`, `system_0`) unique within one transcript
    - `db_id` in YAML is a persistent UUID that can track the same person across meetings
    - Confidence values are included when Transcripted has enough information

    ## Common Agent Tasks

    **Summarize latest meeting:**
    Sort `Call_*.md` files by filename or file modified date, then summarize the newest transcript.

    **Extract action items:**
    Read the full transcript and pull out task-like language with speaker names and timestamps.

    **Track speaker across meetings:**
    Use `db_id` and speaker names in YAML to connect people across meeting files.

    **Search by topic:**
    Scan the Markdown transcript text across `Call_*.md` files.
    """

    /// Write CLAUDE.md and AGENT.md to the save directory.
    public static func writeAgentReadme(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for filename in ["CLAUDE.md", "AGENT.md"] {
            let fileURL = folder.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: fileURL.path),
               !shouldReplaceGeneratedAgentReadme(at: fileURL) {
                continue
            }
            try? agentReadmeContent.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private static func shouldReplaceGeneratedAgentReadme(at fileURL: URL) -> Bool {
        guard let existing = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return false
        }
        return existing.contains("Transcripted")
            && existing.contains("Meeting Data")
            && (
                existing.contains("| `transcripted.json` | Index")
                    || existing.contains("| `Call_*.json` | Structured JSON sidecar")
                    || existing.contains("Read `transcripted.json`")
            )
    }

    /// Generate a paste-ready prompt for connecting an AI agent.
    public static func clipboardPrompt(folder: URL, filename: String?) -> String {
        var prompt = """
        I use Transcripted to record meetings locally on my Mac.
        My transcripts are saved at: \(folder.path)

        To get started:
        1. Read AGENT.md for the folder notes
        2. Read the local Call_*.md meeting files
        3. Use YAML metadata, speaker analytics, timestamps, and transcript text

        Each transcript has persistent speaker IDs that track people across meetings.
        """

        if let filename = filename {
            let markdownFilename = filename.hasSuffix(".md") ? filename : "\(filename).md"
            prompt += "\n\nStart with: \(markdownFilename)"
        }

        return prompt
    }
}

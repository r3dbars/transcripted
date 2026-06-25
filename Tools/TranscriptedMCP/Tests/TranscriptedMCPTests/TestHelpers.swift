import Foundation
@testable import transcripted_mcp

func makeFixtureJSON(
    title: String? = nil,
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
) -> String {
    let dateComponents = splitDateTime(date)
    let totalWordCount = utterances.reduce(0) { partial, utterance in
        partial + utterance.text.split(whereSeparator: \.isWhitespace).count
    }
    let micUtterances = utterances.filter { $0.speakerId.hasPrefix("mic_") }
    let systemUtterances = utterances.filter { $0.speakerId.hasPrefix("system_") }
    let micSpeakerCount = Set(micUtterances.map(\.speakerId)).count
    let systemSpeakerCount = Set(systemUtterances.map(\.speakerId)).count

    // Entry shape and key order mirror TranscriptFormatter.formatTranscriptMarkdown.
    let speakerLines = speakers
        .filter { $0.id.hasPrefix("system_") }
        .map { speaker -> String in
            let rawId = speaker.id.replacingOccurrences(of: "system_", with: "")
            var lines = [
                "  - id: \"\(rawId)\"",
                "    channel: system"
            ]
            if let persistentId = speaker.persistentId {
                lines.append("    db_id: \"\(persistentId)\"")
            }
            lines.append("    name: \"\(speaker.name)\"")
            lines.append("    confidence: high")
            lines.append("    source: db_scan")
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n")

    let speakerLookup = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
    let transcriptBody = utterances.map { utterance -> String in
        let source = utterance.speakerId.hasPrefix("mic_") ? "Mic" : "System"
        let label = speakerLookup[utterance.speakerId] ?? utterance.speakerId
        return "[\(formatTimestamp(utterance.start))] [\(source)/\(label)] \(utterance.text)"
    }.joined(separator: "\n\n")

    let groupedSystemUtterances = Dictionary(grouping: systemUtterances, by: \.speakerId)
    let breakdown = groupedSystemUtterances.keys.sorted().map { speakerId -> String in
        let grouped = groupedSystemUtterances[speakerId] ?? []
        let name = speakerLookup[speakerId] ?? speakerId
        let wordCount = grouped.reduce(0) { partial, utterance in
            partial + utterance.text.split(whereSeparator: \.isWhitespace).count
        }
        let speakingSeconds = grouped.reduce(0.0) { partial, utterance in
            partial + max(0, utterance.end - utterance.start)
        }
        return "- **\(name):** \(grouped.count) utterances, ~\(wordCount) words, \(formatDuration(seconds: Int(speakingSeconds.rounded())))"
    }.joined(separator: "\n")

    let titleLine = title.map { "title: \"\($0)\"\n" } ?? ""

    return """
    ---
    \(titleLine)transcript_id: "\(UUID().uuidString)"
    date: \(dateComponents.date)
    time: \(dateComponents.time)
    duration: "\(formatDuration(seconds: durationSeconds))"
    processing_time: "3.0s"
    transcription_engine: parakeet_local
    diarization_engine: pyannote_offline
    sources: [mic, system_audio]
    mic_utterances: \(micUtterances.count)
    system_utterances: \(systemUtterances.count)
    mic_speakers: \(micSpeakerCount)
    system_speakers: \(systemSpeakerCount)
    total_word_count: \(totalWordCount)
    capture_quality: degraded
    audio_gaps: 1
    device_switches: 0
    gap_events:
      - "Audio gap at 00:42 (1.5s)"
    audio_health: mic_attenuated_by_call_app
    mic_boost_prompt: "Mic level was boosted after a call app attenuated it."
    speakers:
    \(speakerLines)
    tags:
      - transcripted
      - meeting
    aliases:
      - "Meeting \(dateComponents.date) \(dateComponents.time)"
    cssclasses:
      - transcripted
    ---

    # Meeting Fixture

    **Duration:** \(formatDuration(seconds: durationSeconds)) | **Words:** \(totalWordCount) | **Utterances:** \(utterances.count)

    ---

    ## Channel & Speaker Analytics

    ### Microphone (You)
    - **Utterances:** \(micUtterances.count)
    - **Words:** ~\(micUtterances.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count })
    - **Speaking Time:** \(formatDuration(seconds: Int(micUtterances.reduce(0.0) { $0 + ($1.end - $1.start) }.rounded())))

    ### Meeting Audio (Remote Participants)
    - **Utterances:** \(systemUtterances.count)
    - **Words:** ~\(systemUtterances.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count })
    - **Speaking Time:** \(formatDuration(seconds: Int(systemUtterances.reduce(0.0) { $0 + ($1.end - $1.start) }.rounded())))
    - **Speakers Detected:** \(systemSpeakerCount)

    #### Remote Speaker Breakdown

    \(breakdown)

    ---

    ## Full Transcript

    \(transcriptBody)

    ---

    *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: \(formatDuration(seconds: durationSeconds)) | \(totalWordCount) words | \(max(1, systemSpeakerCount + micSpeakerCount)) speakers*
    """
}

func writeFixture(_ content: String, filename: String, to directory: URL) throws {
    let path = directory.appendingPathComponent("\(filename).md")
    try content.write(to: path, atomically: true, encoding: .utf8)
}

/// Minimal meeting transcript carrying an inline local summary, mirroring what
/// LocalMeetingSummaryMarkdownUpdater writes: `local_summary_*` frontmatter keys
/// plus a marker-bounded `## Local Summary` body block with `###` subsections.
func makeMeetingWithInlineSummary(
    date: String = "2026-04-18",
    time: String = "09:15:00",
    decisions: [String] = ["Ship the beta on Friday", "Cut the legacy import path"],
    actionItems: [String] = ["Jenny: send the revised spec", "Follow up with legal"],
    openQuestions: [String] = ["Do we need a migration window?"]
) -> String {
    func block(_ heading: String, _ items: [String]) -> String {
        let body = items.isEmpty ? "- None found." : items.map { "- \($0)" }.joined(separator: "\n")
        return "\(heading)\n\(body)"
    }
    func frontmatter(_ items: [String]) -> String {
        items.isEmpty ? "None found." : items.joined(separator: " | ")
    }
    return """
    ---
    capture_type: meeting
    date: \(date)
    time: \(time)
    duration: "30:00"
    transcription_engine: parakeet_local
    diarization_engine: pyannote_offline
    local_summary_version: "1"
    local_summary_title: "Beta launch sync"
    local_summary_decisions: "\(frontmatter(decisions))"
    local_summary_action_items: "\(frontmatter(actionItems))"
    local_summary_open_questions: "\(frontmatter(openQuestions))"
    ---

    # Meeting

    ## Full Transcript

    [00:00] [System/Jenny] Let's lock the launch.

    <!-- transcripted:local-summary:start v=1 -->
    ## Local Summary

    ### Summary
    - The team aligned on launch.

    \(block("### Decisions", decisions))

    \(block("### Open Questions", openQuestions))

    \(block("### Action Items", actionItems))
    <!-- transcripted:local-summary:end -->
    """
}

func makeDictationDayJSON(
    date: String = "2026-04-07",
    markdownFilename: String = "Dictations_2026-04-07.md",
    entries: [(id: String, createdAt: String, title: String, text: String, sourceAppName: String, delivery: String)] = [
        ("dictation-20260407-091500-000", "2026-04-07T09:15:00-0500", "Morning note", "Ship the follow-up note to product today", "Slack", "copied"),
        ("dictation-20260407-183000-000", "2026-04-07T18:30:00-0500", "Evening note", "Remember to send the recap before dinner", "Mail", "pasted"),
    ]
) -> String {
    let title = "Dictations for \(date)"
    let sections = entries.map { entry in
        let wordCount = entry.text.split(whereSeparator: \.isWhitespace).count
        let characterCount = entry.text.count
        return """
        ## \(formatDictationHeading(from: entry.createdAt)) - \(entry.title)

        Entry ID: `\(entry.id)`
        Captured: \(normalizedISO(entry.createdAt))
        Source app: \(entry.sourceAppName)
        Bundle ID: `com.example.\(entry.sourceAppName.lowercased())`
        Delivery: \(entry.delivery)
        Words: \(wordCount)
        Characters: \(characterCount)

        \(entry.text)
        """
    }.joined(separator: "\n\n")

    _ = markdownFilename
    return """
    ---
    title: "\(title)"
    date: \(date)
    capture_type: dictation_day
    ---

    # \(title)

    \(sections)
    """
}

func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func removeTempDir(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

private func splitDateTime(_ isoish: String) -> (date: String, time: String) {
    let date = String(isoish.prefix(10))
    let timeStart = isoish.index(isoish.startIndex, offsetBy: 11, limitedBy: isoish.endIndex) ?? isoish.endIndex
    let time = String(isoish[timeStart...].prefix(8))
    return (date, time.isEmpty ? "00:00:00" : time)
}

private func formatTimestamp(_ seconds: Double) -> String {
    let totalSeconds = Int(seconds.rounded())
    let minutes = totalSeconds / 60
    let remainingSeconds = totalSeconds % 60
    return String(format: "%02d:%02d", minutes, remainingSeconds)
}

private func formatDuration(seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remainingSeconds = seconds % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%02d:%02d", minutes, remainingSeconds)
}

private func formatDictationHeading(from createdAt: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"

    guard let date = formatter.date(from: createdAt) else {
        return "12:00 AM"
    }

    let output = DateFormatter()
    output.locale = Locale(identifier: "en_US_POSIX")
    output.dateFormat = "h:mm a"
    return output.string(from: date)
}

private func normalizedISO(_ value: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"

    guard let date = formatter.date(from: value) else {
        return value
    }

    let output = ISO8601DateFormatter()
    output.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return output.string(from: date)
}

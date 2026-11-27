import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// The compact `format_version: 2` frontmatter the restyle writes, and the
/// pipeline keys it moves out to the hidden `.meta/<capture_id>.json`
/// sidecar. Pure: lines in, lines and sidecar values out.
///
/// Agents read the Markdown, so its frontmatter keeps what helps them
/// (identity, when, how long, words, speakers) plus any flag that is set or
/// abnormal. Healthy defaults and engine plumbing go to the sidecar. Keys
/// this file doesn't know are kept, in their original order.
enum MeetingTranscriptV2Frontmatter {
    static let formatVersion = 2

    struct Output: Equatable {
        /// Frontmatter lines without the `---` fences.
        let lines: [String]
        /// What left the Markdown, as sidecar values (strings, or a string
        /// array for `gap_events`). Empty when nothing moved.
        let movedValues: [String: MeetingMetadataSidecar.Value]
        let captureID: UUID?
    }

    /// Always moved out of the Markdown.
    static let movedKeys: Set<String> = [
        "processing_time", "transcription_engine", "diarization_engine", "voiceprint_model",
        "mic_utterances", "system_utterances", "mic_speakers", "sources", "transcript_id",
    ]

    /// Re-emitted in this order at the top; everything else keeps its order.
    private static let headKeys = [
        "capture_id", "capture_type", "format_version", "transcript_style",
        "recorded_at", "date", "time", "duration", "total_word_count",
    ]

    /// Gap events shorter than this are reconnect noise, not lost audio.
    static let minimumReportedGapSeconds = 1.0

    static func render(
        lines: [String],
        titleLine: String,
        recordedAt: Date
    ) -> Output {
        let entries = entries(in: lines)
        let values = TranscriptFrontmatter.values(from: lines)
        var moved: [String: MeetingMetadataSidecar.Value] = [:]
        var kept: [Entry] = []
        var head: [String: [String]] = [:]

        let captureIDText = values["capture_id"] ?? values["transcript_id"]
        let captureID = captureIDText.flatMap(UUID.init(uuidString:))
        let keptGapEvents = gapEvents(in: entries).filter { !isSubSecondGap($0) }
        let droppedGapCount = gapEvents(in: entries).count - keptGapEvents.count

        func keepIf(_ keep: Bool, _ entry: Entry, _ value: String) {
            if keep {
                kept.append(entry)
            } else {
                moved[entry.key ?? ""] = .string(value)
            }
        }

        for entry in entries {
            guard let key = entry.key else {
                kept.append(entry)
                continue
            }
            let value = values[key] ?? ""
            switch key {
            case "title", "transcript_style", "format_version", "recorded_at":
                continue
            case "capture_id", "capture_type", "date", "time", "duration", "total_word_count":
                head[key] = entry.lines
            case "sources":
                // `[mic, system_audio]`, kept as a list.
                let list = value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                moved[key] = .list(list)
            case _ where movedKeys.contains(key):
                moved[key] = .string(value)
            case "system_speakers":
                keepIf((Int(value) ?? 0) > 0, entry, value)
            case "capture_quality":
                keepIf(value == "fair" || value == "degraded", entry, value)
            case "device_switches":
                keepIf((Int(value) ?? 0) > 0, entry, value)
            case "system_audio_signal_verified":
                keepIf(value != "true", entry, value)
            case "audio_gaps":
                // The raw values go to the sidecar only when this pass changes
                // them, so a later pass never overwrites them with filtered ones.
                let count = max(0, (Int(value) ?? 0) - droppedGapCount)
                if count > 0 {
                    kept.append(count == Int(value) ? entry : Entry(key: key, lines: ["audio_gaps: \(count)"]))
                }
                if count != Int(value) { moved[key] = .string(value) }
            case "gap_events":
                if !keptGapEvents.isEmpty {
                    kept.append(droppedGapCount == 0 ? entry : Entry(
                        key: key,
                        lines: ["gap_events:"] + keptGapEvents.map { "  - \(TranscriptFrontmatter.quotedYAMLScalar($0))" }
                    ))
                }
                if droppedGapCount > 0 || keptGapEvents.isEmpty {
                    moved[key] = .list(gapEvents(in: entries))
                }
            case "transcription_language":
                keepIf(value != "auto", entry, value)
            case "transcription_language_resolution", "transcription_language_resolved":
                keepIf(keepsResolvedLanguage(values), entry, value)
            default:
                kept.append(entry)
            }
        }

        if head["capture_id"] == nil, let captureIDText {
            head["capture_id"] = ["capture_id: \(TranscriptFrontmatter.quotedYAMLScalar(captureIDText))"]
        }
        head["format_version"] = ["format_version: \(formatVersion)"]
        head["transcript_style"] = ["transcript_style: styled"]
        head["recorded_at"] = ["recorded_at: \(recordedAtString(recordedAt))"]
        if head["date"] == nil {
            head["date"] = ["date: \(DateFormattingHelper.formatDayStamp(recordedAt))"]
            head["time"] = head["time"] ?? ["time: \(DateFormattingHelper.formatTimeOfDay(recordedAt))"]
        }

        let output = [titleLine]
            + headKeys.flatMap { head[$0] ?? [] }
            + kept.flatMap(\.lines)
        return Output(lines: output, movedValues: moved, captureID: captureID)
    }

    /// Keep the detected language only when it names one: Automatic that
    /// stayed uncertain, mixed or unsupported tells an agent nothing.
    private static func keepsResolvedLanguage(_ values: [String: String]) -> Bool {
        if let selection = values["transcription_language"], selection != "auto" { return true }
        guard let resolution = values["transcription_language_resolution"],
              resolution == "detected" || resolution == "explicit",
              let resolved = values["transcription_language_resolved"], !resolved.isEmpty else {
            return false
        }
        return true
    }

    /// `2026-11-26T19:58:41-06:00`: the recording start in the Mac's time zone.
    static func recordedAtString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Entries

    /// A top-level key with its indented continuation lines (nested blocks
    /// such as `speakers:` and `gap_events:`). Lines before the first key
    /// have no key.
    private struct Entry: Equatable {
        let key: String?
        let lines: [String]
    }

    private static func entries(in lines: [String]) -> [Entry] {
        var entries: [Entry] = []
        for line in lines {
            if line.first?.isWhitespace == true || line.isEmpty, let last = entries.last {
                entries[entries.count - 1] = Entry(key: last.key, lines: last.lines + [line])
                continue
            }
            let key = line.split(separator: ":", maxSplits: 1).first.map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            entries.append(Entry(key: line.contains(":") ? key : nil, lines: [line]))
        }
        return entries
    }

    private static func gapEvents(in entries: [Entry]) -> [String] {
        guard let block = entries.last(where: { $0.key == "gap_events" }) else { return [] }
        return block.lines.dropFirst().compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { return nil }
            return TranscriptFrontmatter.unquoteYAMLScalar(String(trimmed.dropFirst(2)))
        }
    }

    /// Gap events read `<reason>: <seconds>s` (`Audio.AudioGap.description`).
    static func isSubSecondGap(_ event: String) -> Bool {
        guard event.hasSuffix("s"),
              let colon = event.lastIndex(of: ":") else { return false }
        let number = event[event.index(after: colon)...]
            .dropLast()
            .trimmingCharacters(in: .whitespaces)
        guard let seconds = Double(number) else { return false }
        return seconds < minimumReportedGapSeconds
    }
}

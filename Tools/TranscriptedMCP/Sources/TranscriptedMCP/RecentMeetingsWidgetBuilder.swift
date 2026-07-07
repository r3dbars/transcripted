import Foundation
import TranscriptedCaptureKit

/// Builds the recent-meetings widget model from the local capture library. This
/// reuses the same meeting/transcript/audio access the read tools use — it adds
/// a UI layer on top of the existing data surface, it does not re-plumb data.
///
/// Everything served here is local: transcripts are read from the capture
/// Markdown, audio bytes from the sibling `audio/<stem>_audio/` bundle. The bytes
/// are base64-inlined into the widget and travel over the local stdio transport;
/// nothing is fetched from or sent to a remote host.
enum RecentMeetingsWidgetBuilder {
    /// Per-meeting inline audio ceiling. Above this the card shows the audio
    /// folder path instead of embedding — keeps a single widget response bounded.
    /// Inlining is deliberately capped: base64 audio travels in the tool result,
    /// and some hosts limit message size. Longer recordings fall back to the
    /// local path (the future scaling path is lazy fetch over the postMessage
    /// bridge, documented in docs/mcp-ui-recent-meetings.md).
    static let defaultMaxAudioBytesPerMeeting = 4 * 1024 * 1024
    /// Whole-widget inline audio ceiling across all cards.
    static let defaultMaxAudioBytesTotal = 8 * 1024 * 1024

    /// Preferred playback stems, best-listening first — mirrors the app's
    /// `MeetingAudioArchiveResolver` ordering so the widget plays the same track
    /// the app would.
    private static let preferredStems = ["playback", "recording", "system_audio", "microphone"]
    private static let audioExtensions = ["m4a", "wav", "aiff", "aif", "mp3", "caf", "flac"]

    static func build(
        index: TranscriptIndex,
        meetingDirs: [URL],
        count: Int,
        generatedDate: String,
        serverName: String,
        serverVersion: String,
        maxAudioBytesPerMeeting: Int = defaultMaxAudioBytesPerMeeting,
        maxAudioBytesTotal: Int = defaultMaxAudioBytesTotal
    ) throws -> RecentMeetingsWidgetModel {
        let summaries = try index.listMeetings(count: count)
        var meetings: [WidgetMeeting] = []
        var audioBudget = maxAudioBytesTotal

        for summary in summaries {
            guard let mdURL = resolveMeetingFile(named: summary.filename, in: meetingDirs) else {
                meetings.append(placeholder(from: summary))
                continue
            }
            let content = CaptureMarkdown.readBoundedContents(of: mdURL) ?? ""
            let title = CaptureMarkdown.extractTitle(from: content) ?? summary.title ?? summary.filename
            let transcript = transcriptText(from: content)
            let speakerNames = summary.speakers.map(\.name)

            let audioDir = audioDirectory(for: mdURL)
            let (audio, note) = resolveAudio(
                in: audioDir, perMeetingCap: maxAudioBytesPerMeeting, remainingBudget: audioBudget
            )
            if let audio { audioBudget -= audio.sizeBytes }

            meetings.append(WidgetMeeting(
                title: title,
                date: summary.date,
                datetime: summary.datetime,
                durationSeconds: summary.durationSeconds,
                speakers: speakerNames,
                wordCount: summary.wordCount,
                filename: summary.filename,
                transcript: transcript,
                audio: audio,
                audioDirectory: FileManager.default.fileExists(atPath: audioDir.path) ? audioDir.path : nil,
                audioNote: note
            ))
        }

        return RecentMeetingsWidgetModel(
            serverName: serverName,
            serverVersion: serverVersion,
            generatedDate: generatedDate,
            meetings: meetings
        )
    }

    /// Resolve a meeting Markdown file across the configured meeting directories,
    /// applying the shared traversal/symlink guard.
    private static func resolveMeetingFile(named name: String, in dirs: [URL]) -> URL? {
        for dir in dirs {
            if case .valid(let url) = PathSecurity.resolveReadableFile(named: name, appendingExtension: "md", in: dir) {
                return url
            }
        }
        return nil
    }

    // MARK: - Transcript

    /// Speaker-labeled dialogue, bounded by the same read cap the read tools use
    /// so one long meeting can't blow out the widget payload.
    static func transcriptText(from content: String) -> String {
        guard let parsed = CaptureMarkdownParser.parseMeeting(from: content),
              !parsed.utterances.isEmpty else {
            // Fall back to the raw dialogue block for files the parser can't window.
            return boundedDialogue(from: content)
        }
        let names = Dictionary(uniqueKeysWithValues: parsed.speakers.map { ($0.id, $0.name) })
        var out = ""
        for utterance in parsed.utterances {
            let speaker = names[utterance.speakerId] ?? utterance.speakerId
            let line = "\(speaker): \(utterance.text)\n"
            if out.count + line.count > maxUnpaginatedReadCharacters {
                out += "\n… transcript truncated. Use read_meeting \"\(parsed.datetime)\" for the full text."
                break
            }
            out += line
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boundedDialogue(from content: String) -> String {
        let markers = ["## Full Transcript\n", "## Transcript\n"]
        guard let range = markers.compactMap({ content.range(of: $0) }).first else { return "" }
        let body = String(content[range.upperBound...])
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.hasPrefix("*Generated by") && $0 != "---" }
            .joined(separator: "\n")
        if body.count > maxUnpaginatedReadCharacters {
            return String(body.prefix(maxUnpaginatedReadCharacters)) + "\n… transcript truncated."
        }
        return body
    }

    // MARK: - Audio

    /// `<meetingDir>/audio/<stem>_audio/` — the same layout the app writes via
    /// `MeetingArtifactRenamer.audioDirectoryURL`.
    static func audioDirectory(for transcriptURL: URL) -> URL {
        transcriptURL
            .deletingLastPathComponent()
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("\(transcriptURL.deletingPathExtension().lastPathComponent)_audio", isDirectory: true)
    }

    /// Resolve the preferred playback file and, if it fits the caps, base64-inline
    /// it. Returns `(nil, note)` when audio is missing or too large, so the card
    /// can fall back to the folder path.
    private static func resolveAudio(
        in audioDir: URL,
        perMeetingCap: Int,
        remainingBudget: Int
    ) -> (WidgetAudio?, String?) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: audioDir.path, isDirectory: &isDir), isDir.boolValue else {
            return (nil, "No recording found")
        }
        guard let fileURL = preferredAudioFile(in: audioDir) else {
            return (nil, "No recording found")
        }
        // The audio dir is derived from an already-validated transcript URL; confirm
        // the chosen file is a real regular file under it (no symlink escape).
        guard case .valid(let safeURL) = PathSecurity.validateExistingFile(fileURL, under: audioDir) else {
            return (nil, "Recording unavailable")
        }

        let size = (try? safeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let cap = min(perMeetingCap, remainingBudget)
        if size > cap {
            let mb = String(format: "%.1f", Double(size) / 1_048_576)
            return (nil, "Recording (\(mb) MB) too large to embed")
        }
        guard let data = try? Data(contentsOf: safeURL), !data.isEmpty else {
            return (nil, "Recording unavailable")
        }

        let stem = safeURL.deletingPathExtension().lastPathComponent
        let mime = mimeType(forExtension: safeURL.pathExtension)
        let uri = "data:\(mime);base64,\(data.base64EncodedString())"
        return (WidgetAudio(dataURI: uri, mimeType: mime, label: label(forStem: stem), sizeBytes: data.count), nil)
    }

    private static func preferredAudioFile(in audioDir: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let audioFiles = files.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        guard !audioFiles.isEmpty else { return nil }
        for stem in preferredStems {
            if let match = audioFiles.first(where: { $0.deletingPathExtension().lastPathComponent == stem }) {
                return match
            }
        }
        return audioFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    private static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "m4a", "mp4", "caf": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        default: return "audio/mp4"
        }
    }

    private static func label(forStem stem: String) -> String {
        switch stem {
        case "playback": return "Mix"
        case "recording": return "Recording"
        case "system_audio": return "System"
        case "microphone": return "Mic"
        default: return "Audio"
        }
    }

    private static func placeholder(from summary: MeetingSummary) -> WidgetMeeting {
        WidgetMeeting(
            title: summary.title ?? summary.filename,
            date: summary.date,
            datetime: summary.datetime,
            durationSeconds: summary.durationSeconds,
            speakers: summary.speakers.map(\.name),
            wordCount: summary.wordCount,
            filename: summary.filename,
            transcript: "",
            audio: nil,
            audioDirectory: nil,
            audioNote: "Meeting file unavailable"
        )
    }
}

// SpeakerVoiceprintMigrationEvidence.swift
// Where a voiceprint migration finds each named person's audio:
//
//   - the saved review clip, `<speakerClips>/<profile UUID>.wav` (up to 8 s,
//     overwritten by each review, so it is that person's most recent reviewed
//     voice), plus clips still keyed by profiles that were merged into them;
//   - retained meeting audio, `<meetings>/audio/<transcript stem>_audio/`
//     (`system_audio.*` or an import's `recording.*` for the call side,
//     `microphone.*` for the room), located in time by the saved transcript:
//     its frontmatter `speakers:` block ties each body label to a `db_id`, and
//     each body row gives a start time on that label's track.
//
// Exemplar rows in the database carry no audio reference (only vectors and a
// session count), so they can't be re-embedded; the count is reported so a
// host can compare "sessions the old voiceprint was built from" with "audio
// still on disk".

import Accelerate
import AVFoundation
import Foundation

/// One saved meeting that names a person the migration carries over.
struct SpeakerVoiceprintMeetingEvidence: Sendable {
    struct Label: Sendable, Hashable {
        let channel: UtteranceChannel
        let name: String
    }

    let transcriptURL: URL
    let transcriptId: UUID?
    let recordedAt: Date?
    /// Body labels that belong to this person and to nobody else in the meeting.
    let labels: Set<Label>
    /// The user named or confirmed this person in this meeting (frontmatter
    /// `source: user_manual`, or a confirmation-ledger row for this transcript).
    /// Otherwise the old model silently recognized them (`source: db`).
    let confirmed: Bool
    /// Retained audio per track, when still on disk.
    let tracks: [UtteranceChannel: URL]

    var usableLabels: Set<Label> { labels.filter { tracks[$0.channel] != nil } }
}

enum SpeakerVoiceprintTranscriptScan {

    /// Frontmatter `source:` values that mean this row's name was accepted:
    /// the user named or confirmed it, or the old model auto-accepted it.
    /// `db_pending` and `unknown` rows were never accepted and are skipped.
    static let acceptedSources: Set<String> = [NameSource.userManual, "db"]

    /// Every saved meeting under `meetingsDirectory` that names someone in
    /// `peopleIds`, grouped by person. Reads only frontmatter and a directory
    /// listing per meeting; transcript bodies are read later, per person.
    static func meetings(
        under meetingsDirectory: URL,
        snapshot: SpeakerVoiceprintSourceSnapshot,
        peopleIds: Set<UUID>,
        isCancelled: () -> Bool = { false }
    ) -> [UUID: [SpeakerVoiceprintMeetingEvidence]] {
        guard !peopleIds.isEmpty else { return [:] }
        var result: [UUID: [SpeakerVoiceprintMeetingEvidence]] = [:]
        for url in TranscriptSaver.transcriptMarkdownFiles(under: meetingsDirectory) {
            if isCancelled() { break }
            guard let document = try? TranscriptFrontmatter.readDocument(from: url) else { continue }
            if let captureType = document.values["capture_type"], captureType != "meeting" { continue }
            let speakers = frontmatterSpeakers(in: document.lines)
            guard !speakers.isEmpty else { continue }

            let transcriptId = TranscriptFrontmatter.captureID(in: document.values)
            var owners: [SpeakerVoiceprintMeetingEvidence.Label: Set<UUID?>] = [:]
            var labelsByPerson: [UUID: Set<SpeakerVoiceprintMeetingEvidence.Label>] = [:]
            var confirmedPeople: Set<UUID> = []
            for speaker in speakers {
                guard let name = speaker.name, !name.isEmpty else { continue }
                let label = SpeakerVoiceprintMeetingEvidence.Label(channel: speaker.channel, name: name)
                let person = speaker.dbId.map(snapshot.survivor(of:)).flatMap { peopleIds.contains($0) ? $0 : nil }
                owners[label, default: []].insert(person)
                guard let person, let source = speaker.source, acceptedSources.contains(source) else { continue }
                labelsByPerson[person, default: []].insert(label)
                let ledgerConfirmed = transcriptId.map { id in
                    snapshot.confirmations[person, default: []].contains { $0.transcriptId == id.uuidString }
                } ?? false
                if source == NameSource.userManual || ledgerConfirmed {
                    confirmedPeople.insert(person)
                }
            }
            guard !labelsByPerson.isEmpty else { continue }

            let tracks = retainedTracks(forTranscript: url)
            let recordedAt = TranscriptFrontmatter.recordedAt(values: document.values)
            for (person, labels) in labelsByPerson {
                // A label two different speakers share can't be told apart in the body.
                let unambiguous = labels.filter { owners[$0]?.count == 1 }
                guard !unambiguous.isEmpty else { continue }
                result[person, default: []].append(SpeakerVoiceprintMeetingEvidence(
                    transcriptURL: url,
                    transcriptId: transcriptId,
                    recordedAt: recordedAt,
                    labels: unambiguous,
                    confirmed: confirmedPeople.contains(person),
                    tracks: tracks
                ))
            }
        }
        return result
    }

    // MARK: - Frontmatter

    struct FrontmatterSpeaker: Equatable {
        var channel: UtteranceChannel = .system
        var dbId: UUID?
        var name: String?
        var source: String?
    }

    /// Rows of the nested `speakers:` block (see docs/capture-format.md). `lines`
    /// are the frontmatter lines between the `---` delimiters. Rows without a
    /// channel are system rows, as older files wrote them.
    static func frontmatterSpeakers(in lines: [String]) -> [FrontmatterSpeaker] {
        var rows: [FrontmatterSpeaker] = []
        var current: FrontmatterSpeaker?
        var inBlock = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let indent = line.prefix(while: { $0 == " " }).count
            if !inBlock {
                if indent == 0, trimmed == "speakers:" { inBlock = true }
                continue
            }
            if !trimmed.isEmpty, indent == 0 { break }

            var body = trimmed
            if body.hasPrefix("- ") {
                if let row = current { rows.append(row) }
                current = FrontmatterSpeaker()
                body = String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            guard current != nil else { continue }

            if body.hasPrefix("db_id:") {
                current?.dbId = TranscriptSaver.extractYAMLQuotedString(from: body, prefix: "db_id: ")
                    .flatMap(UUID.init(uuidString:))
            } else if body.hasPrefix("name:") {
                current?.name = TranscriptSaver.extractYAMLQuotedString(from: body, prefix: "name: ")
            } else if body.hasPrefix("channel:") {
                let raw = plainValue(body.dropFirst("channel:".count))
                current?.channel = UtteranceChannel(rawValue: raw) ?? .system
            } else if body.hasPrefix("source:") {
                current?.source = plainValue(body.dropFirst("source:".count))
            }
        }
        if let row = current { rows.append(row) }
        return rows
    }

    private static func plainValue(_ raw: Substring) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    // MARK: - Body rows

    private static let styledHeader = try? NSRegularExpression(
        pattern: #"^\*\*([0-9]+(?::[0-9]+){1,2})\*\*\s+\[(Mic|System)/(.+)\]$"#
    )

    /// Every transcript row in a saved meeting's body, raw (`[MM:SS] [System/Ann] text`)
    /// or styled (`**MM:SS**  [System/Ann]`). `knownLabels` are tried first so a
    /// name containing `] ` still parses whole.
    static func transcriptRows(
        in markdown: String,
        knownLabels: [String] = []
    ) -> [SpeakerVoiceprintMigrationPolicy.TranscriptRow] {
        let body = TranscriptFrontmatter.body(in: markdown) ?? markdown
        let labelsLongestFirst = knownLabels.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        var rows: [SpeakerVoiceprintMigrationPolicy.TranscriptRow] = []
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if let row = rawRow(line, knownLabels: labelsLongestFirst) ?? styledRow(line) {
                rows.append(row)
            }
        }
        return rows
    }

    private static func rawRow(
        _ line: String,
        knownLabels: [String]
    ) -> SpeakerVoiceprintMigrationPolicy.TranscriptRow? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        guard let start = seconds(fromTimestamp: String(line[line.index(after: line.startIndex)..<close])) else {
            return nil
        }
        let rest = line[line.index(after: close)...]
        let channel: UtteranceChannel
        let afterSource: Substring
        if rest.hasPrefix(" [Mic/") {
            channel = .mic
            afterSource = rest.dropFirst(" [Mic/".count)
        } else if rest.hasPrefix(" [System/") {
            channel = .system
            afterSource = rest.dropFirst(" [System/".count)
        } else {
            return nil
        }
        for known in knownLabels {
            for candidate in [known, "[[\(known)]]"] where afterSource.hasPrefix(candidate + "] ") || afterSource == candidate + "]" {
                return .init(start: start, channel: channel, label: known)
            }
        }
        let label: Substring
        if let end = afterSource.range(of: "] ") {
            label = afterSource[..<end.lowerBound]
        } else if afterSource.hasSuffix("]") {
            label = afterSource.dropLast()
        } else {
            return nil
        }
        return .init(start: start, channel: channel, label: unwrapWikiLink(String(label)))
    }

    private static func styledRow(_ line: String) -> SpeakerVoiceprintMigrationPolicy.TranscriptRow? {
        guard line.hasPrefix("**"), let regex = styledHeader else { return nil }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 4,
              let start = seconds(fromTimestamp: ns.substring(with: match.range(at: 1))) else {
            return nil
        }
        let channel: UtteranceChannel = ns.substring(with: match.range(at: 2)) == "Mic" ? .mic : .system
        return .init(start: start, channel: channel, label: unwrapWikiLink(ns.substring(with: match.range(at: 3))))
    }

    /// `MM:SS` (minutes may exceed 59) or `H:MM:SS`, in seconds.
    static func seconds(fromTimestamp timestamp: String) -> Double? {
        let parts = timestamp.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let values = parts.compactMap { $0 }
        return Double(values.reduce(0) { $0 * 60 + $1 })
    }

    private static func unwrapWikiLink(_ label: String) -> String {
        guard label.hasPrefix("[["), label.hasSuffix("]]"), label.count >= 4 else { return label }
        return String(label.dropFirst(2).dropLast(2))
    }

    // MARK: - Retained audio

    /// The retained tracks next to a saved transcript, the way the app lays them
    /// out: `<transcript folder>/audio/<transcript stem>_audio/`.
    static func retainedTracks(forTranscript transcriptURL: URL) -> [UtteranceChannel: URL] {
        let directory = transcriptURL.deletingLastPathComponent()
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("\(transcriptURL.deletingPathExtension().lastPathComponent)_audio", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        let regular = files.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        func first(_ stem: String) -> URL? {
            regular
                .filter { $0.deletingPathExtension().lastPathComponent == stem }
                .sorted { $0.pathExtension.localizedCaseInsensitiveCompare($1.pathExtension) == .orderedAscending }
                .first
        }
        var tracks: [UtteranceChannel: URL] = [:]
        // An import is one `recording.*` file, transcribed as the call side.
        tracks[.system] = first("system_audio") ?? first("recording")
        // `microphone_placeholder.*` is the silent stand-in for a missing mic; never used.
        tracks[.mic] = first("microphone")
        return tracks
    }
}

/// Reads stretches of saved audio as 16 kHz mono, the input every
/// `SpeakerSegmentEmbedder` takes.
enum SpeakerVoiceprintAudioReader {
    static let sampleRate = 16_000

    /// Peak below this is digital silence (a padded gap, a mic-only meeting's
    /// silent call track) and is not a voice.
    static let silencePeak: Float = 1e-4

    static func open(_ url: URL) -> AVAudioFile? {
        guard let file = try? AVAudioFile(forReading: url),
              AudioRecordingFormatPolicy.isUsableSampleRate(file.processingFormat.sampleRate),
              file.processingFormat.channelCount > 0,
              file.length > 0 else { return nil }
        return file
    }

    static func duration(of file: AVAudioFile) -> Double {
        Double(file.length) / file.processingFormat.sampleRate
    }

    /// `range` of `file` as 16 kHz mono, or nil when it is past the end,
    /// unreadable, or silent.
    static func samples(
        from file: AVAudioFile,
        range: SpeakerVoiceprintMigrationPolicy.TimeRange
    ) -> [Float]? {
        let format = file.processingFormat
        let rate = format.sampleRate
        guard range.start.isFinite, range.end.isFinite, range.seconds > 0 else { return nil }
        let startFrame = AVAudioFramePosition((range.start * rate).rounded(.down))
        guard startFrame >= 0, startFrame < file.length else { return nil }
        let wanted = min(AVAudioFramePosition((range.seconds * rate).rounded(.down)), file.length - startFrame)
        guard wanted > 0, wanted <= AVAudioFramePosition(Int32.max) else { return nil }

        let chunk: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        let channelCount = Int(format.channelCount)
        var mono: [Float] = []
        mono.reserveCapacity(Int(wanted))
        file.framePosition = startFrame
        while mono.count < Int(wanted) {
            let toRead = min(chunk, AVAudioFrameCount(Int(wanted) - mono.count))
            do {
                try file.read(into: buffer, frameCount: toRead)
            } catch {
                break
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            if channelCount == 1 {
                mono.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            } else {
                var mixed = [Float](repeating: 0, count: frames)
                mixed.withUnsafeMutableBufferPointer { out in
                    guard let base = out.baseAddress else { return }
                    for channel in 0..<channelCount {
                        vDSP_vadd(base, 1, data[channel], 1, base, 1, vDSP_Length(frames))
                    }
                    var scale = 1 / Float(channelCount)
                    vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(frames))
                }
                mono.append(contentsOf: mixed)
            }
        }
        guard !mono.isEmpty else { return nil }
        var peak: Float = 0
        mono.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress!, 1, &peak, vDSP_Length($0.count)) }
        guard peak >= silencePeak, peak.isFinite else { return nil }
        guard rate != Double(sampleRate) else { return mono }
        if let converted = try? AudioResampler.resampleForSpeech(mono, from: rate, to: Double(sampleRate)),
           !converted.isEmpty {
            return converted
        }
        let linear = AudioResampler.resample(mono, from: rate, to: Double(sampleRate))
        return linear.isEmpty ? nil : linear
    }
}

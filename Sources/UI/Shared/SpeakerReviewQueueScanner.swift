import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct SpeakerPendingReviewItem: Identifiable, Sendable {
    let speakerId: UUID
    let diarizerSpeakerId: String
    let channel: UtteranceChannel
    let transcriptURL: URL
    let meetingTitle: String
    let recordedAt: Date?
    let fallbackDate: Date
    let sampleText: String?
    let clipURL: URL?
    let callCount: Int
    let profile: SpeakerProfile
    let sourceName: String

    var id: String {
        [
            speakerId.uuidString,
            transcriptURL.path,
            channel.rawValue,
            diarizerSpeakerId
        ].joined(separator: "|")
    }

    var speakerLabel: String {
        "\(channelPrefix)/\(sourceName)"
    }

    private var channelPrefix: String {
        switch channel {
        case .mic:
            return "Mic"
        case .system:
            return "System"
        }
    }
}

struct SpeakerPendingVoiceGroup: Identifiable, Sendable {
    let representative: SpeakerPendingReviewItem
    let meetingCount: Int
    let sampleText: String?

    var id: UUID { representative.speakerId }
}

enum SpeakerReviewQueueScanner {
    private static let excludedMarkdownFilenames: Set<String> = ["AGENT.md", "CLAUDE.md"]
    private static let reviewPreviewByteLimit = 256 * 1024

    static func loadPendingItems(
        transcriptsDirectory: URL = MeetingStoragePaths.transcriptsFolder,
        profiles: [SpeakerProfile],
        clipURLsByProfileID: [UUID: URL]
    ) -> [SpeakerPendingReviewItem] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: transcriptsDirectory.path),
              let urls = try? fileManager.contentsOfDirectory(
                at: transcriptsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let profilesById = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })

        let items = urls.flatMap { url -> [SpeakerPendingReviewItem] in
            guard isMarkdownCandidate(url, fileManager: fileManager),
                  let markdown = readMarkdownPreview(from: url) else {
                return []
            }

            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let fileDate = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            return pendingItems(
                in: markdown,
                transcriptURL: url,
                fileDate: fileDate,
                profilesById: profilesById,
                clipURLsByProfileID: clipURLsByProfileID
            )
        }

        return items.sorted { lhs, rhs in
            let lhsDate = lhs.recordedAt ?? lhs.fallbackDate
            let rhsDate = rhs.recordedAt ?? rhs.fallbackDate
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            if lhs.meetingTitle != rhs.meetingTitle {
                return lhs.meetingTitle.localizedCaseInsensitiveCompare(rhs.meetingTitle) == .orderedAscending
            }
            return lhs.speakerLabel.localizedCaseInsensitiveCompare(rhs.speakerLabel) == .orderedAscending
        }
    }

    static func pendingItems(
        in markdown: String,
        transcriptURL: URL,
        fileDate: Date = .distantPast,
        profilesById: [UUID: SpeakerProfile],
        clipURLsByProfileID: [UUID: URL]
    ) -> [SpeakerPendingReviewItem] {
        guard let document = TranscriptFrontmatter.document(in: markdown) else { return [] }

        let meetingTitle = normalizedTitle(
            document.values["title"],
            fallbackURL: transcriptURL
        )
        let recordedAt = TranscriptFrontmatter.recordedAt(values: document.values)

        let items: [SpeakerPendingReviewItem] = frontmatterSpeakers(from: document.lines).compactMap { speaker in
            guard speaker.source == "db_pending",
                  let dbId = speaker.dbId,
                  let profile = profilesById[dbId],
                  profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                return nil
            }

            return SpeakerPendingReviewItem(
                speakerId: dbId,
                diarizerSpeakerId: speaker.id,
                channel: speaker.channel,
                transcriptURL: transcriptURL,
                meetingTitle: meetingTitle,
                recordedAt: recordedAt,
                fallbackDate: fileDate,
                sampleText: sampleText(
                    in: document.body,
                    speakerName: speaker.name,
                    channel: speaker.channel
                ),
                clipURL: clipURLsByProfileID[dbId],
                callCount: profile.callCount,
                profile: profile,
                sourceName: speaker.name
            )
        }

        return deduplicatedPendingItems(items)
    }

    /// Collapses the per-meeting review queue into one entry per distinct voice.
    /// Items are expected newest-first (the order `loadPendingItems` returns), so
    /// each group's representative is that voice's most recent appearance.
    static func groupedByVoice(_ items: [SpeakerPendingReviewItem]) -> [SpeakerPendingVoiceGroup] {
        var order: [UUID] = []
        var itemsBySpeakerID: [UUID: [SpeakerPendingReviewItem]] = [:]

        for item in items {
            if itemsBySpeakerID[item.speakerId] == nil {
                order.append(item.speakerId)
            }
            itemsBySpeakerID[item.speakerId, default: []].append(item)
        }

        return order.compactMap { speakerId in
            guard let groupItems = itemsBySpeakerID[speakerId],
                  let representative = groupItems.first else {
                return nil
            }

            let transcriptPaths = Set(groupItems.map { $0.transcriptURL.standardizedFileURL.path })
            let sampleText = groupItems
                .first { $0.sampleText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }?
                .sampleText
            return SpeakerPendingVoiceGroup(
                representative: representative,
                meetingCount: transcriptPaths.count,
                sampleText: sampleText
            )
        }
    }

    private static func deduplicatedPendingItems(_ items: [SpeakerPendingReviewItem]) -> [SpeakerPendingReviewItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private struct FrontmatterSpeaker {
        let id: String
        let channel: UtteranceChannel
        let dbId: UUID?
        let name: String
        let source: String
    }

    private static func frontmatterSpeakers(from lines: [String]) -> [FrontmatterSpeaker] {
        var speakers: [FrontmatterSpeaker] = []
        var inSpeakersBlock = false
        var current: [String: String]?

        func finishCurrent() {
            guard let current,
                  let id = current["id"],
                  let name = current["name"],
                  let source = current["source"] else {
                return
            }

            let channel = current["channel"]
                .flatMap { UtteranceChannel(rawValue: $0) } ?? .system
            speakers.append(FrontmatterSpeaker(
                id: id,
                channel: channel,
                dbId: current["db_id"].flatMap(UUID.init(uuidString:)),
                name: name,
                source: source
            ))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "speakers:" {
                inSpeakersBlock = true
                continue
            }

            guard inSpeakersBlock else { continue }

            if !line.hasPrefix("  "), !trimmed.isEmpty {
                finishCurrent()
                current = nil
                break
            }

            if trimmed.hasPrefix("- ") {
                finishCurrent()
                current = [:]
                let keyValue = String(trimmed.dropFirst(2))
                writeKeyValue(keyValue, into: &current)
            } else if current != nil {
                writeKeyValue(trimmed, into: &current)
            }
        }

        finishCurrent()
        return speakers
    }

    private static func writeKeyValue(_ line: String, into current: inout [String: String]?) {
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalizeFrontmatterValue(parts[1])
        current?[key] = value
    }

    private static func normalizeFrontmatterValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func normalizedTitle(_ title: String?, fallbackURL: URL) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return fallbackURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func sampleText(
        in body: String,
        speakerName: String,
        channel: UtteranceChannel
    ) -> String? {
        let label = "[\(channelPrefix(for: channel))/\(speakerName)]"
        let lines = body.components(separatedBy: .newlines)

        for index in lines.indices {
            let line = lines[index]
            guard let labelRange = line.range(of: label) else { continue }

            let sameLine = String(line[labelRange.upperBound...])
            if let cleaned = cleanedSample(sameLine) {
                return cleaned
            }

            for nextIndex in lines.indices where nextIndex > index && nextIndex <= index + 4 {
                if let cleaned = cleanedSample(lines[nextIndex]) {
                    return cleaned
                }
            }
        }

        return nil
    }

    private static func channelPrefix(for channel: UtteranceChannel) -> String {
        switch channel {
        case .mic:
            return "Mic"
        case .system:
            return "System"
        }
    }

    private static func cleanedSample(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.hasPrefix("---"),
              !looksLikeSpeakerLine(trimmed) else {
            return nil
        }

        if trimmed.count <= 160 { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 157)
        return String(trimmed[..<end]) + "..."
    }

    private static func looksLikeSpeakerLine(_ line: String) -> Bool {
        line.hasPrefix("**") || line.hasPrefix("[")
    }

    private static func isMarkdownCandidate(_ url: URL, fileManager: FileManager) -> Bool {
        guard url.pathExtension == "md", !excludedMarkdownFilenames.contains(url.lastPathComponent) else {
            return false
        }

        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
           values.isRegularFile == false {
            return false
        }

        return true
    }

    private static func readMarkdownPreview(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: reviewPreviewByteLimit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

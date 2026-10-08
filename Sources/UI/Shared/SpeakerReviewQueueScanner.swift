import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// A transcript-local preview. It never becomes the saved sample of an
/// unconfirmed global speaker profile.
struct SpeakerRetainedAudioSample: Equatable, Sendable {
    let url: URL
    let startTime: TimeInterval
    let duration: TimeInterval
}

struct SpeakerPendingReviewItem: Identifiable, Sendable {
    let speakerId: UUID
    let diarizerSpeakerId: String
    let channel: SpeakerReviewChannel
    let transcriptURL: URL
    let transcriptId: UUID?
    let meetingTitle: String
    let recordedAt: Date?
    let fallbackDate: Date
    let sampleText: String?
    let clipURL: URL?
    let retainedAudioSample: SpeakerRetainedAudioSample?
    let callCount: Int
    let profile: SpeakerProfile
    let sourceName: String
    /// The meeting's length, for the per-call card in Speakers.
    var meetingDurationSeconds: Int? = nil
    /// Imported recordings have no calendar slot, so no invitees.
    var isImported = false

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

/// One call with voices still waiting for a name, for the "Name these
/// people" cards in Speakers. A voice heard in several calls shows once,
/// under the most recent one; naming it there names it everywhere.
struct SpeakerPendingMeetingGroup: Identifiable, Sendable {
    let transcriptURL: URL
    let transcriptId: UUID?
    let meetingTitle: String
    let recordedAt: Date?
    let fallbackDate: Date
    let durationSeconds: Int?
    let isImported: Bool
    let voices: [SpeakerPendingVoiceGroup]

    var id: String { SpeakerReviewSkippedCalls.key(transcriptId: transcriptId, transcriptURL: transcriptURL) }
}

/// Calls someone chose to skip in "Name these people". Saved, unlike the
/// per-voice Skip, so a skipped call stays skipped after a restart; its
/// voices stay reachable under Everyone.
enum SpeakerReviewSkippedCalls {
    static let defaultsKey = "speakerReviewSkippedCalls"
    private static let limit = 500

    static func key(transcriptId: UUID?, transcriptURL: URL) -> String {
        transcriptId?.uuidString ?? transcriptURL.standardizedFileURL.path
    }

    static func load(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    static func add(_ key: String, defaults: UserDefaults = .standard) {
        var keys = defaults.stringArray(forKey: defaultsKey) ?? []
        guard !keys.contains(key) else { return }
        keys.append(key)
        defaults.set(Array(keys.suffix(limit)), forKey: defaultsKey)
    }
}

enum SpeakerReviewQueueScanner {
    private static let excludedMarkdownFilenames: Set<String> = ["AGENT.md", "CLAUDE.md"]
    private static let reviewPreviewByteLimit = 256 * 1024
    private static let noPendingSpeakersCache = NoPendingSpeakersCache()
    private static let pendingSummaryCache = PendingSummaryCache()

    /// Remembers transcripts that had no pending speakers the last time they
    /// were read, keyed by path plus modification date and size. The Speakers
    /// page rescans after every rename, merge, and meeting save; without this
    /// each rescan re-read up to 256 KB of every saved meeting.
    final class NoPendingSpeakersCache: @unchecked Sendable {
        struct Fingerprint: Equatable {
            let modifiedAt: Date?
            let size: Int?
        }

        private static let maxEntries = 20_000
        private let lock = NSLock()
        private var entries: [String: Fingerprint] = [:]

        func contains(_ url: URL, fingerprint: Fingerprint) -> Bool {
            guard fingerprint.modifiedAt != nil else { return false }
            lock.lock()
            defer { lock.unlock() }
            return entries[url.standardizedFileURL.path] == fingerprint
        }

        func insert(_ url: URL, fingerprint: Fingerprint) {
            guard fingerprint.modifiedAt != nil else { return }
            lock.lock()
            defer { lock.unlock() }
            if entries.count >= Self.maxEntries {
                entries.removeAll(keepingCapacity: true)
            }
            entries[url.standardizedFileURL.path] = fingerprint
        }
    }

    /// The other half: for transcripts that do list `db_pending` speakers,
    /// remembers what `pendingItems` read from the file (title, dates, the
    /// pending speakers and their sample lines), keyed the same way. Users who
    /// rarely name voices keep most meetings pending, so without this every
    /// rescan re-read and re-parsed nearly every transcript. Profiles, clips
    /// and audio files are still checked fresh on each scan.
    fileprivate final class PendingSummaryCache: @unchecked Sendable {
        private static let maxEntries = 20_000
        private let lock = NSLock()
        private var entries: [String: (fingerprint: NoPendingSpeakersCache.Fingerprint, summary: PendingSummary)] = [:]

        func summary(for url: URL, fingerprint: NoPendingSpeakersCache.Fingerprint) -> PendingSummary? {
            guard fingerprint.modifiedAt != nil else { return nil }
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[url.standardizedFileURL.path], entry.fingerprint == fingerprint else { return nil }
            return entry.summary
        }

        func insert(_ summary: PendingSummary, for url: URL, fingerprint: NoPendingSpeakersCache.Fingerprint) {
            guard fingerprint.modifiedAt != nil else { return }
            lock.lock()
            defer { lock.unlock() }
            if entries.count >= Self.maxEntries {
                entries.removeAll(keepingCapacity: true)
            }
            entries[url.standardizedFileURL.path] = (fingerprint, summary)
        }
    }

    static func loadPendingItems(
        transcriptsDirectory: URL = MeetingStoragePaths.transcriptsFolder,
        profiles: [SpeakerProfile],
        clipURLsByProfileID: [UUID: URL]
    ) -> [SpeakerPendingReviewItem] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: transcriptsDirectory.path),
              let urls = try? fileManager.contentsOfDirectory(
                at: transcriptsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let profilesById = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })

        let items = urls.flatMap { url -> [SpeakerPendingReviewItem] in
            guard isMarkdownCandidate(url, fileManager: fileManager) else {
                return []
            }

            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
            )
            let fingerprint = values.map {
                NoPendingSpeakersCache.Fingerprint(
                    modifiedAt: $0.contentModificationDate,
                    size: $0.fileSize
                )
            }
            // Most saved meetings have no unnamed voices. Skip re-reading
            // those until the file changes (naming a speaker rewrites it).
            if let fingerprint, noPendingSpeakersCache.contains(url, fingerprint: fingerprint) {
                return []
            }
            let fileDate = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            // An unchanged pending transcript is rebuilt from what was read
            // last time, unless a voice lost its clip since and the summary
            // was made without the transcript lines that fallback needs.
            if let fingerprint,
               let summary = pendingSummaryCache.summary(for: url, fingerprint: fingerprint),
               summary.hasLineWindows || !summary.needsAudioFallback(clipURLsByProfileID: clipURLsByProfileID) {
                return pendingItems(
                    from: summary,
                    transcriptURL: url,
                    fileDate: fileDate,
                    profilesById: profilesById,
                    clipURLsByProfileID: clipURLsByProfileID
                )
            }
            guard let markdown = readMarkdownPreview(from: url) else {
                return []
            }
            if let fingerprint, !hasPendingSpeakers(in: markdown) {
                noPendingSpeakersCache.insert(url, fingerprint: fingerprint)
                return []
            }

            guard let summary = pendingSummary(
                in: markdown,
                transcriptURL: url,
                clipURLsByProfileID: clipURLsByProfileID
            ) else {
                return []
            }
            if let fingerprint {
                pendingSummaryCache.insert(summary, for: url, fingerprint: fingerprint)
            }
            return pendingItems(
                from: summary,
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

    /// True when the transcript lists any `db_pending` speaker. Without one,
    /// `pendingItems` is empty whatever the current profiles are.
    static func hasPendingSpeakers(in markdown: String) -> Bool {
        guard let document = TranscriptFrontmatter.document(in: markdown) else { return false }
        return frontmatterSpeakers(from: document.lines).contains { $0.source == "db_pending" }
    }

    static func pendingItems(
        in markdown: String,
        transcriptURL: URL,
        fileDate: Date = .distantPast,
        profilesById: [UUID: SpeakerProfile],
        clipURLsByProfileID: [UUID: URL]
    ) -> [SpeakerPendingReviewItem] {
        guard let summary = pendingSummary(
            in: markdown,
            transcriptURL: transcriptURL,
            clipURLsByProfileID: clipURLsByProfileID
        ) else { return [] }
        return pendingItems(
            from: summary,
            transcriptURL: transcriptURL,
            fileDate: fileDate,
            profilesById: profilesById,
            clipURLsByProfileID: clipURLsByProfileID
        )
    }

    /// What `pendingItems` needs from one transcript, independent of the
    /// current profiles, clips and audio files.
    fileprivate struct PendingSummary: Sendable {
        struct Speaker: Sendable {
            let speaker: FrontmatterSpeaker
            let sampleText: String?
            /// The retained-audio preview window when the voice plays from
            /// the mixed recording, and when it plays from its own channel.
            /// Nil when the summary was made without transcript lines.
            let mixedWindow: SampleWindow?
            let channelWindow: SampleWindow?
        }

        let meetingTitle: String
        let recordedAt: Date?
        let transcriptId: UUID?
        let meetingDuration: Int?
        let isImported: Bool
        /// Only the `db_pending` speakers, in frontmatter order.
        let speakers: [Speaker]
        let hasLineWindows: Bool

        func needsAudioFallback(clipURLsByProfileID: [UUID: URL]) -> Bool {
            speakers.contains { $0.speaker.dbId.map { clipURLsByProfileID[$0] == nil } == true }
        }
    }

    fileprivate struct SampleWindow: Sendable {
        let startTime: TimeInterval
        let duration: TimeInterval
        let text: String?
    }

    private static func pendingSummary(
        in markdown: String,
        transcriptURL: URL,
        clipURLsByProfileID: [UUID: URL]
    ) -> PendingSummary? {
        guard let document = TranscriptFrontmatter.document(in: markdown) else { return nil }

        let meetingDuration = TranscriptFrontmatter.durationSeconds(from: document.values["duration"])
        let pendingSpeakers = frontmatterSpeakers(from: document.lines).filter { $0.source == "db_pending" }
        let needsAudioFallback = pendingSpeakers.contains {
            $0.dbId.map { clipURLsByProfileID[$0] == nil } == true
        }
        let transcriptLines = needsAudioFallback ? HomeMeetingPreviewContent.make(from: markdown).transcriptLines : []

        return PendingSummary(
            meetingTitle: normalizedTitle(document.values["title"], fallbackURL: transcriptURL),
            recordedAt: TranscriptFrontmatter.recordedAt(values: document.values),
            transcriptId: TranscriptFrontmatter.captureID(in: document.values),
            meetingDuration: meetingDuration,
            isImported: document.values["imported_at"] != nil,
            speakers: pendingSpeakers.map { speaker in
                PendingSummary.Speaker(
                    speaker: speaker,
                    sampleText: sampleText(in: document.body, speakerName: speaker.name, channel: speaker.channel),
                    mixedWindow: needsAudioFallback ? sampleWindow(
                        for: speaker, lines: transcriptLines, fromMixedAudio: true, meetingDuration: meetingDuration
                    ) : nil,
                    channelWindow: needsAudioFallback ? sampleWindow(
                        for: speaker, lines: transcriptLines, fromMixedAudio: false, meetingDuration: meetingDuration
                    ) : nil
                )
            },
            hasLineWindows: needsAudioFallback
        )
    }

    private static func pendingItems(
        from summary: PendingSummary,
        transcriptURL: URL,
        fileDate: Date,
        profilesById: [UUID: SpeakerProfile],
        clipURLsByProfileID: [UUID: URL]
    ) -> [SpeakerPendingReviewItem] {
        let audio = summary.needsAudioFallback(clipURLsByProfileID: clipURLsByProfileID)
            ? MeetingAudioArchiveResolver.attachment(forTranscript: transcriptURL)
            : nil

        let items: [SpeakerPendingReviewItem] = summary.speakers.compactMap { entry in
            let speaker = entry.speaker
            guard let dbId = speaker.dbId,
                  let profile = profilesById[dbId],
                  profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                return nil
            }

            let clipURL = clipURLsByProfileID[dbId]
            let fallback = clipURL == nil ? retainedSample(for: entry, audio: audio) : nil
            return SpeakerPendingReviewItem(
                speakerId: dbId,
                diarizerSpeakerId: speaker.id,
                channel: speaker.channel,
                transcriptURL: transcriptURL,
                transcriptId: summary.transcriptId,
                meetingTitle: summary.meetingTitle,
                recordedAt: summary.recordedAt,
                fallbackDate: fileDate,
                sampleText: fallback?.text ?? entry.sampleText,
                clipURL: clipURL,
                retainedAudioSample: fallback?.sample,
                callCount: profile.callCount,
                profile: profile,
                sourceName: speaker.name,
                meetingDurationSeconds: summary.meetingDuration,
                isImported: summary.isImported
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

    /// Groups voices under the call they were last heard in, newest call
    /// first (voices arrive newest-first from `groupedByVoice`).
    static func groupedByMeeting(_ voices: [SpeakerPendingVoiceGroup]) -> [SpeakerPendingMeetingGroup] {
        var order: [String] = []
        var voicesByKey: [String: [SpeakerPendingVoiceGroup]] = [:]
        for voice in voices {
            let item = voice.representative
            let key = SpeakerReviewSkippedCalls.key(transcriptId: item.transcriptId, transcriptURL: item.transcriptURL)
            if voicesByKey[key] == nil { order.append(key) }
            voicesByKey[key, default: []].append(voice)
        }
        return order.compactMap { key in
            guard let groupVoices = voicesByKey[key], let item = groupVoices.first?.representative else { return nil }
            return SpeakerPendingMeetingGroup(
                transcriptURL: item.transcriptURL,
                transcriptId: item.transcriptId,
                meetingTitle: item.meetingTitle,
                recordedAt: item.recordedAt,
                fallbackDate: item.fallbackDate,
                durationSeconds: item.meetingDurationSeconds,
                isImported: item.isImported,
                voices: groupVoices
            )
        }
    }

    private static func deduplicatedPendingItems(_ items: [SpeakerPendingReviewItem]) -> [SpeakerPendingReviewItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    fileprivate struct FrontmatterSpeaker: Sendable {
        let id: String
        let channel: SpeakerReviewChannel
        let dbId: UUID?
        let name: String
        let source: String
    }

    private static func retainedSample(
        for entry: PendingSummary.Speaker,
        audio: MeetingAudioAttachment?
    ) -> (sample: SpeakerRetainedAudioSample, text: String?)? {
        guard let audio else { return nil }
        let speaker = entry.speaker
        let urls = audio.retranscriptionURLs + audio.urls
        let channelStem = speaker.channel == .mic
            ? MeetingAudioArchiveResolver.microphoneStem : MeetingAudioArchiveResolver.systemStem
        let channelURL = urls.first { $0.deletingPathExtension().lastPathComponent == channelStem }
        let importedURL = speaker.channel == .system
            ? urls.first { $0.deletingPathExtension().lastPathComponent == MeetingAudioArchiveResolver.importedStem }
            : nil
        let mixedURL = urls.first { $0.deletingPathExtension().lastPathComponent == MeetingAudioArchiveResolver.playbackStem }
        guard let url = channelURL ?? importedURL ?? mixedURL else { return nil }
        guard let window = url == mixedURL ? entry.mixedWindow : entry.channelWindow else { return nil }
        return (
            SpeakerRetainedAudioSample(url: url, startTime: window.startTime, duration: window.duration),
            window.text
        )
    }

    /// The first utterance of `speaker` that makes a usable preview, as a
    /// time window plus its text. From the mixed recording any next turn ends
    /// the window; from a channel file only the next turn on that channel does.
    private static func sampleWindow(
        for speaker: FrontmatterSpeaker,
        lines: [HomeMeetingTranscriptLine],
        fromMixedAudio: Bool,
        meetingDuration: Int?
    ) -> SampleWindow? {
        for (index, line) in lines.enumerated() {
            // Styled transcripts omit the channel prefix. The existing parser
            // resolves their identity only when the frontmatter match is unique.
            guard line.identity.persistentSpeakerID == speaker.dbId,
                  line.identity.diarizerSpeakerID == speaker.id,
                  line.identity.channel == nil || line.identity.channel?.rawValue == speaker.channel.rawValue,
                  let start = timestampSeconds(line.time) else { continue }
            var end = start + 8
            if let next = lines.dropFirst(index + 1).first(where: {
                fromMixedAudio || $0.identity.channel == nil
                    || $0.identity.channel?.rawValue == speaker.channel.rawValue
            }) {
                // Never preview across the next turn on this source. Equal or
                // reversed timestamps are ambiguous, so try another utterance.
                guard let nextStart = timestampSeconds(next.time), nextStart > start else { continue }
                end = min(end, nextStart)
            }
            if let meetingDuration { end = min(end, TimeInterval(meetingDuration)) }
            guard end > start else { continue }
            return SampleWindow(startTime: start, duration: end - start, text: cleanedSample(line.text))
        }
        return nil
    }

    private static func timestampSeconds(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let seconds = Int(parts[parts.count - 1]), seconds < 60,
              parts.count != 3 || (Int(parts[1]).map { $0 < 60 } == true),
              let total = TranscriptFrontmatter.durationSeconds(from: value) else { return nil }
        return TimeInterval(total)
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
                .flatMap { SpeakerReviewChannel(rawValue: $0) } ?? .system
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
        channel: SpeakerReviewChannel
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

    private static func channelPrefix(for channel: SpeakerReviewChannel) -> String {
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

        // Pool the read so a scan over many files doesn't keep every buffer alive.
        return autoreleasepool(invoking: { () -> String? in
            guard let data = try? handle.read(upToCount: reviewPreviewByteLimit) else { return nil }
            return String(decoding: data, as: UTF8.self)
        })
    }
}

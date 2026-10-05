import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum RecentMeetingsScanner {
    private static let excludedMarkdownFilenames: Set<String> = ["AGENT.md", "CLAUDE.md"]

    /// Classifies the meetings folder without loading rows. `loadRecent` fails
    /// closed (returns `[]`) for both a missing folder and a damaged path, which
    /// is correct for the list but hides breakage from the user — Home calls this
    /// to tell those two cases apart and warn only on real damage.
    static func diagnose(directory: URL? = nil) -> RecentMeetingsScanDiagnosis {
        let dir = directory ?? MeetingStoragePaths.transcriptsFolder
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory) else {
            return .missingFolder
        }
        guard isDirectory.boolValue else {
            return .damagedPath(reason: .notADirectory)
        }
        do {
            _ = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return .damagedPath(reason: .unreadable)
        }
        return .ok
    }

    static func loadRecent(
        limit: Int = 3,
        directory: URL? = nil,
        cache: RecentMeetingMetadataCache? = .shared
    ) -> [RecentMeetingItem] {
        loadRecentWithDiagnosis(limit: limit, directory: directory, cache: cache).items
    }

    /// The warning and rows come from the same listing, avoiding a second scan.
    static func loadRecentWithDiagnosis(
        limit: Int = 3,
        directory: URL? = nil,
        cache: RecentMeetingMetadataCache? = .shared
    ) -> (items: [RecentMeetingItem], diagnosis: RecentMeetingsScanDiagnosis) {
        guard limit > 0 else { return ([], .ok) }

        let dir = directory ?? MeetingStoragePaths.transcriptsFolder
        let fm = FileManager.default

        // Self-heal before scanning: drop cached rows whose transcript no longer
        // exists so deleted/moved meetings (and any fixture rows a mis-scoped
        // caller wrote) can't strand the Home list. This runs on the background
        // refresh task, so the `stat`-per-row cost stays off the main thread.
        if Task.isCancelled { return ([], .ok) }
        cache?.pruneMissingPathsIfNeeded(fileManager: fm)

        guard !Task.isCancelled else { return ([], .ok) }
        var diagnosis = RecentMeetingsScanDiagnosis.ok
        guard let candidates = scanCandidates(in: dir, fileManager: fm, diagnosis: &diagnosis) else {
            return ([], diagnosis)
        }

        var recentItems: [RecentMeetingItem] = []
        for entry in candidates.sorted(by: { $0.date > $1.date }) {
            if Task.isCancelled { return ([], .ok) }

            let stamp = RecentMeetingCacheStamp(
                transcriptModified: entry.modified,
                transcriptSize: entry.size
            )

            // Warm path: serve the row straight from the index, with no transcript
            // content read. Only the live audio attachment is resolved.
            if let cache,
               let cached = cache.lookup(path: entry.url.path, stamp: stamp) {
                recentItems.append(
                    cached.makeItem(
                        transcriptURL: entry.url,
                        audio: MeetingAudioArchiveResolver.attachment(forTranscript: entry.url)
                    )
                )
                if recentItems.count >= limit {
                    break
                }
                continue
            }

            // Cold path: parse the transcript, then populate the index so the next
            // refresh stays off disk.
            guard let item = parseItem(at: entry.url, fallbackDate: entry.date, resolveAudio: true) else {
                continue
            }
            cache?.store(
                path: entry.url.path,
                stamp: stamp,
                metadata: CachedRecentMeetingMetadata(item: item)
            )
            recentItems.append(item)
            if recentItems.count >= limit {
                break
            }
        }

        return (recentItems, diagnosis)
    }

    /// Every saved meeting, newest first, for the Home meetings search. Rows
    /// come back without audio attachments (a directory probe per row is the
    /// expensive part at thousands of meetings); the caller resolves audio for
    /// the few matches it shows.
    ///
    /// Row lookup order keeps repeat searches cheap:
    /// 1. `previous` (the last index, in memory) when the file stamp is unchanged
    /// 2. the SQLite metadata cache, read in one query
    /// 3. a full transcript parse, which then fills the cache
    ///
    /// Returns `nil` when cancelled, so a stale partial list is never published.
    static func loadSearchIndex(
        directory: URL? = nil,
        cache: RecentMeetingMetadataCache? = .shared,
        previous: [String: RecentMeetingIndexEntry] = [:]
    ) -> [RecentMeetingIndexEntry]? {
        loadIndex(directory: directory, cache: cache, previous: previous, includeSpeakerDetails: true)
    }

    /// Today needs title and recording time, never the transcript's speaker
    /// labels. Keep its bounded preview rows separate from the full search cache.
    static func loadTodayIndex(
        directory: URL? = nil,
        cache: RecentMeetingMetadataCache? = .shared,
        previous: [String: RecentMeetingIndexEntry] = [:]
    ) -> [RecentMeetingIndexEntry]? {
        loadIndex(directory: directory, cache: cache, previous: previous, includeSpeakerDetails: false)
    }

    private static func loadIndex(
        directory: URL?,
        cache: RecentMeetingMetadataCache?,
        previous: [String: RecentMeetingIndexEntry],
        includeSpeakerDetails: Bool
    ) -> [RecentMeetingIndexEntry]? {
        let dir = directory ?? MeetingStoragePaths.transcriptsFolder
        let fm = FileManager.default

        cache?.pruneMissingPathsIfNeeded(fileManager: fm)

        guard fm.fileExists(atPath: dir.path) else { return [] }
        var diagnosis = RecentMeetingsScanDiagnosis.ok
        guard let candidates = scanCandidates(in: dir, fileManager: fm, diagnosis: &diagnosis) else { return nil }

        func cacheStamp(for candidate: ScanCandidate) -> RecentMeetingCacheStamp {
            RecentMeetingCacheStamp(
                transcriptModified: candidate.modified,
                transcriptSize: candidate.size
            )
        }

        // A warm rebuild usually misses only a file or two (a new save); look
        // those up one by one instead of decoding the whole cache table.
        let missCount = candidates.lazy.filter { previous[$0.url.path]?.stamp != cacheStamp(for: $0) }.count
        let cachedRows: [String: RecentMeetingMetadataCache.Row]? =
            missCount > singleLookupMissLimit ? cache?.allRows() : nil

        // The first search after an upgrade reparses the whole library; write
        // those rows in batched transactions rather than one fsync per row.
        // Rows parsed before a cancel are still flushed, so the work is kept.
        var pendingCacheRows: [(path: String, stamp: RecentMeetingCacheStamp, metadata: CachedRecentMeetingMetadata)] = []
        defer { cache?.store(pendingCacheRows) }

        var entries: [RecentMeetingIndexEntry] = []
        entries.reserveCapacity(candidates.count)
        for candidate in candidates {
            if Task.isCancelled { return nil }
            let path = candidate.url.path
            let stamp = cacheStamp(for: candidate)

            if let reused = previous[path], reused.stamp == stamp {
                entries.append(reused)
                continue
            }

            let cachedMetadata: CachedRecentMeetingMetadata?
            if let cachedRows {
                cachedMetadata = cachedRows[path].flatMap { $0.stamp == stamp ? $0.metadata : nil }
            } else {
                cachedMetadata = cache?.lookup(path: path, stamp: stamp)
            }
            if let cachedMetadata {
                entries.append(
                    RecentMeetingIndexEntry(
                        path: path,
                        stamp: stamp,
                        item: cachedMetadata.makeItem(transcriptURL: candidate.url, audio: nil)
                    )
                )
                continue
            }

            guard let item = parseItem(
                at: candidate.url, fallbackDate: candidate.date,
                resolveAudio: false, includeSpeakerDetails: includeSpeakerDetails
            ) else {
                continue
            }
            if includeSpeakerDetails {
                pendingCacheRows.append((path, stamp, CachedRecentMeetingMetadata(item: item)))
            }
            if pendingCacheRows.count >= cacheWriteBatchSize {
                cache?.store(pendingCacheRows)
                pendingCacheRows.removeAll(keepingCapacity: true)
            }
            entries.append(RecentMeetingIndexEntry(path: path, stamp: stamp, item: item))
        }

        // Rows are listed by file date, but the Home list shows the recorded
        // start time; sort on that so search results read newest first.
        entries.sort { $0.item.date > $1.item.date }
        return entries
    }

    /// Below this many rows missing from the previous index, the search
    /// index build uses per-row cache lookups instead of `allRows()`.
    private static let singleLookupMissLimit = 32
    /// Parsed rows per cache transaction during a search index build.
    private static let cacheWriteBatchSize = 200

    private struct ScanCandidate {
        let url: URL
        let date: Date
        let modified: Double
        let size: Int64
    }

    private static func scanCandidates(
        in dir: URL, fileManager fm: FileManager, diagnosis: inout RecentMeetingsScanDiagnosis
    ) -> [ScanCandidate]? {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory) else {
            diagnosis = .missingFolder
            return []
        }
        guard isDirectory.boolValue else {
            diagnosis = .damagedPath(reason: .notADirectory)
            return []
        }
        let keys: [URLResourceKey] = [
            .creationDateKey, .contentModificationDateKey, .isRegularFileKey, .fileSizeKey
        ]
        let requestedKeys = Set(keys)
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            diagnosis = .damagedPath(reason: .unreadable)
            return []
        }
        // The listing itself can't be interrupted; a cancel that landed while
        // it ran stops here instead of walking thousands of entries.
        if Task.isCancelled { return nil }

        var candidates: [ScanCandidate] = []
        for url in urls {
            if Task.isCancelled { return nil }
            guard isMarkdownCandidate(url) else { continue }
            let values = try? url.resourceValues(forKeys: requestedKeys)
            if values?.isRegularFile == false {
                continue
            }
            candidates.append(
                ScanCandidate(
                    url: url,
                    date: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                    modified: values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0,
                    size: Int64(values?.fileSize ?? 0)
                )
            )
        }
        return candidates
    }

    /// Full parse of one transcript into a Home row (the cache-miss path).
    private static func parseItem(
        at url: URL, fallbackDate: Date, resolveAudio: Bool, includeSpeakerDetails: Bool = true
    ) -> RecentMeetingItem? {
        guard let preview = MeetingTranscriptStyler.readDisplayPreview(at: url) else { return nil }
        let styled = preview.styled
        let markdown = includeSpeakerDetails ? ((try? String(contentsOf: styled.url, encoding: .utf8)) ?? "") : ""
        let frontmatter = includeSpeakerDetails ? TranscriptFrontmatter.document(in: markdown) : preview.frontmatter
        let timing = meetingTiming(
            frontmatter: frontmatter,
            fallbackDate: fallbackDate
        )
        let displayDate = timing.start ?? fallbackDate
        let speakerLabels = RecentMeetingSpeakerStatus.transcriptSpeakerLabels(in: markdown)
        return RecentMeetingItem(
            title: styled.title,
            date: displayDate,
            startDate: timing.start,
            endDate: timing.end,
            transcriptURL: styled.url,
            audio: resolveAudio ? MeetingAudioArchiveResolver.attachment(forTranscript: styled.url) : nil,
            speakerStatus: RecentMeetingSpeakerStatus.detect(speakerLabels: speakerLabels),
            audioHealth: RecentMeetingAudioHealth.detect(frontmatter: frontmatter),
            systemAudioSignalVerified: frontmatter?.values["system_audio_signal_verified"].flatMap(Bool.init),
            speakerNames: RecentMeetingSpeakerStatus.speakerNames(fromLabels: speakerLabels),
            transcriptionEngine: frontmatter?.values["transcription_engine"].flatMap { $0.isEmpty ? nil : $0 },
            importedAt: frontmatter.flatMap { TranscriptFrontmatter.importedAt(values: $0.values) }
        )
    }

    private static func isMarkdownCandidate(_ url: URL) -> Bool {
        url.pathExtension == "md"
            && !url.deletingPathExtension().lastPathComponent.hasSuffix(".summary")
            && !excludedMarkdownFilenames.contains(url.lastPathComponent)
    }

    private static func meetingTiming(
        frontmatter: TranscriptFrontmatterDocument?,
        fallbackDate: Date
    ) -> (start: Date?, end: Date?) {
        guard let frontmatter else { return (fallbackDate, nil) }
        let start = TranscriptFrontmatter.recordedAt(values: frontmatter.values) ?? fallbackDate
        let durationSeconds = TranscriptFrontmatter.durationSeconds(from: frontmatter.values["duration"]) ?? 0
        let end = durationSeconds > 0 ? start.addingTimeInterval(TimeInterval(durationSeconds)) : nil
        return (start, end)
    }

}

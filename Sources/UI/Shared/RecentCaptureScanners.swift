import Foundation

struct RecentMeetingItem: Identifiable {
    let title: String
    let date: Date
    let transcriptURL: URL
    let audio: MeetingAudioAttachment?

    var id: String { transcriptURL.path }
}

@MainActor
enum RecentMeetingsScanner {
    private static let excludedMarkdownFilenames: Set<String> = ["AGENT.md", "CLAUDE.md"]

    static func loadRecent(limit: Int = 3) -> [RecentMeetingItem] {
        guard limit > 0 else { return [] }

        let dir = MeetingStoragePaths.transcriptsFolder
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }

        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let candidates: [(url: URL, date: Date)] = urls.compactMap { url in
            guard isMarkdownCandidate(url, fileManager: fm) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            return (url, date)
        }

        var recentItems: [RecentMeetingItem] = []
        for entry in candidates.sorted(by: { $0.date > $1.date }) {
            guard isMeetingTranscript(entry.url) else { continue }
            let styled = MeetingTranscriptStyler.displayTranscript(at: entry.url)
            recentItems.append(
                RecentMeetingItem(
                    title: styled.title,
                    date: entry.date,
                    transcriptURL: styled.url,
                    audio: MeetingAudioArchiveResolver.attachment(forTranscript: styled.url)
                )
            )
            if recentItems.count >= limit {
                break
            }
        }

        return recentItems
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

    private static func isMeetingTranscript(_ url: URL) -> Bool {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return raw.hasPrefix("---\n") && (raw.contains("\n## Full Transcript") || raw.contains("\n## Transcript"))
    }
}

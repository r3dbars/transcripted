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
        let dir = MeetingStoragePaths.transcriptsFolder
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }

        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let markdowns = urls.filter { isMeetingTranscript($0, fileManager: fm) }
        let items: [(url: URL, date: Date)] = markdowns.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            return (url, date)
        }

        return Array(
            items
                .sorted(by: { $0.date > $1.date })
                .prefix(limit)
                .map { entry in
                    let styled = MeetingTranscriptStyler.displayTranscript(at: entry.url)
                    return RecentMeetingItem(
                        title: styled.title,
                        date: entry.date,
                        transcriptURL: styled.url,
                        audio: MeetingAudioArchiveResolver.attachment(forTranscript: styled.url)
                    )
                }
        )
    }

    private static func isMeetingTranscript(_ url: URL, fileManager: FileManager) -> Bool {
        guard url.pathExtension == "md", !excludedMarkdownFilenames.contains(url.lastPathComponent) else {
            return false
        }

        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
           values.isRegularFile == false {
            return false
        }

        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return raw.hasPrefix("---\n") && (raw.contains("\n## Full Transcript") || raw.contains("\n## Transcript"))
    }
}

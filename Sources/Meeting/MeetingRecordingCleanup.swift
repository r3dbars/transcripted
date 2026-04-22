import Foundation

enum MeetingRecordingCleanup {
    @discardableResult
    static func discardFiles(
        micURL: URL?,
        systemURL: URL?,
        fileManager: FileManager = .default
    ) -> [URL] {
        var discarded: [URL] = []
        let urls = Set([micURL, systemURL].compactMap { $0 })

        for url in urls {
            do {
                try fileManager.removeItem(at: url)
                discarded.append(url)
            } catch {
                continue
            }
        }

        return discarded
    }
}

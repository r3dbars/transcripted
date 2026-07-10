import Foundation

struct TimelineRetentionSummary: Equatable {
    let startingBytes: Int64
    let endingBytes: Int64
    let deletedDatabaseRows: Int
    let deletedFiles: Int
    let deletedOrphanFiles: Int
}

final class TimelineRetentionManager {
    static let defaultStorageCapBytes: Int64 = 5 * 1024 * 1024 * 1024
    static let defaultMaxFilesPerPass = 500

    private let database: TimelineDatabase
    private let screenshotsRoot: URL
    private let fileManager: FileManager
    private let timerQueue = DispatchQueue(label: "com.transcripted.timeline-retention", qos: .utility)
    private var hourlyTimer: DispatchSourceTimer?

    init(
        database: TimelineDatabase,
        screenshotsRoot: URL = FileManager.default.transcriptedTimelineScreenshotsRootURL,
        fileManager: FileManager = .default
    ) {
        self.database = database
        self.screenshotsRoot = screenshotsRoot
        self.fileManager = fileManager
    }

    deinit {
        stopHourlyRetention()
    }

    func startHourlyRetention(
        storageCapBytes: Int64 = TimelineRetentionManager.defaultStorageCapBytes,
        maxFilesPerPass: Int = TimelineRetentionManager.defaultMaxFilesPerPass
    ) {
        stopHourlyRetention()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + .seconds(3600), repeating: .seconds(3600))
        timer.setEventHandler { [weak self] in
            _ = try? self?.runRetentionPass(
                storageCapBytes: storageCapBytes,
                maxFilesPerPass: maxFilesPerPass
            )
        }
        hourlyTimer = timer
        timer.resume()
    }

    func stopHourlyRetention() {
        hourlyTimer?.setEventHandler {}
        hourlyTimer?.cancel()
        hourlyTimer = nil
    }

    func runRetentionPass(
        storageCapBytes: Int64 = TimelineRetentionManager.defaultStorageCapBytes,
        maxFilesPerPass: Int = TimelineRetentionManager.defaultMaxFilesPerPass
    ) throws -> TimelineRetentionSummary {
        let startingBytes = directorySize(screenshotsRoot)
        var endingBytes = startingBytes
        var deletedRows: [Int64] = []
        var remainingFileBudget = max(0, maxFilesPerPass)
        var deletedFiles = 0
        if remainingFileBudget > 0 {
            deletedFiles = try repairPreviouslyDeletedScreenshots(limit: remainingFileBudget)
            remainingFileBudget -= deletedFiles
        }
        var deletedOrphanFiles = 0

        if storageCapBytes >= 0, endingBytes > storageCapBytes, remainingFileBudget > 0 {
            let candidates = try database.oldestPurgeCandidates(limit: remainingFileBudget)

            for candidate in candidates where endingBytes > storageCapBytes && remainingFileBudget > 0 {
                guard let url = fileURL(for: candidate.filePath) else { continue }
                let fileWasPresent = fileManager.fileExists(atPath: url.path)
                let bytes = fileWasPresent ? (fileSize(url) ?? candidate.fileSize) : 0
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                    deletedFiles += 1
                    remainingFileBudget -= 1
                }
                // Delete the file before marking the row. If the process dies
                // after the unlink, the next pass can still remove the now
                // missing row; reversing this order would strand the file
                // behind is_deleted=1 forever.
                try database.markScreenshotsDeleted(ids: [candidate.id])
                endingBytes = max(0, endingBytes - max(0, bytes))
                deletedRows.append(candidate.id)
            }
            try database.hardDeleteScreenshots(ids: deletedRows)
        }

        if remainingFileBudget > 0 {
            let knownPaths = try database.screenshotRelativePaths(includeDeleted: true)
            for orphan in orphanFiles(knownPaths: knownPaths).prefix(remainingFileBudget) {
                let bytes = fileSize(orphan) ?? 0
                try fileManager.removeItem(at: orphan)
                endingBytes = max(0, endingBytes - max(0, bytes))
                deletedOrphanFiles += 1
                remainingFileBudget -= 1
            }
        }

        try database.checkpointWAL()
        return TimelineRetentionSummary(
            startingBytes: startingBytes,
            endingBytes: directorySize(screenshotsRoot),
            deletedDatabaseRows: deletedRows.count,
            deletedFiles: deletedFiles,
            deletedOrphanFiles: deletedOrphanFiles
        )
    }

    private func repairPreviouslyDeletedScreenshots(limit: Int) throws -> Int {
        let candidates = try database.deletedScreenshotCandidates().prefix(limit)
        guard !candidates.isEmpty else { return 0 }

        var deletedFiles = 0
        var repairedIDs: [Int64] = []
        for candidate in candidates {
            if let url = fileURL(for: candidate.filePath), fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                deletedFiles += 1
            }
            repairedIDs.append(candidate.id)
        }

        try database.hardDeleteScreenshots(ids: repairedIDs)
        return deletedFiles
    }

    private func fileURL(for relativePath: String) -> URL? {
        guard !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            return nil
        }
        return screenshotsRoot.appendingPathComponent(relativePath, isDirectory: false)
    }

    private func orphanFiles(knownPaths: Set<String>) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: screenshotsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                continue
            }
            let relative = relativePath(for: url)
            if !knownPaths.contains(relative) {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = screenshotsRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                continue
            }
            total += fileSize(url) ?? 0
        }
        return total
    }

    private func fileSize(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }
}

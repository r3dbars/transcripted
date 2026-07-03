import Foundation
import TranscriptedCaptureKit

struct TranscriptedDataDirectories {
    let meetingDirs: [URL]
    let dictationDirs: [URL]
    let timelineDirs: [URL]
    let indexDir: URL
    let resolutionSource: CaptureLibraryResolutionSource
    let legacyFallbackAppended: Bool

    var meetingsDir: URL {
        meetingDirs[0]
    }

    var dictationsDir: URL {
        dictationDirs[0]
    }

    var timelineDir: URL {
        timelineDirs[0]
    }

    var watchedDirectories: [URL] {
        var seen: Set<String> = []
        var directories: [URL] = []

        for url in meetingDirs + dictationDirs + timelineDirs {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            directories.append(url)
        }

        return directories
    }

    init(
        meetingsDir: URL,
        dictationsDir: URL,
        timelineDir: URL? = nil,
        indexDir: URL,
        resolutionSource: CaptureLibraryResolutionSource = .defaultCaptures,
        legacyFallbackAppended: Bool = false
    ) {
        self.meetingDirs = [meetingsDir]
        self.dictationDirs = [dictationsDir]
        self.timelineDirs = [timelineDir ?? meetingsDir.deletingLastPathComponent().appendingPathComponent("timeline", isDirectory: true)]
        self.indexDir = indexDir
        self.resolutionSource = resolutionSource
        self.legacyFallbackAppended = legacyFallbackAppended
    }

    init(
        meetingDirs: [URL],
        dictationDirs: [URL],
        timelineDirs: [URL] = [],
        indexDir: URL,
        resolutionSource: CaptureLibraryResolutionSource = .defaultCaptures,
        legacyFallbackAppended: Bool = false
    ) {
        self.meetingDirs = meetingDirs
        self.dictationDirs = dictationDirs
        self.timelineDirs = timelineDirs
        self.indexDir = indexDir
        self.resolutionSource = resolutionSource
        self.legacyFallbackAppended = legacyFallbackAppended
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) -> TranscriptedDataDirectories {
        let resolved = CaptureLibraryResolver.resolve(
            environment: environment,
            fileManager: fileManager,
            homeDirectory: homeDirectory
        )
        let indexOverride = environment["TRANSCRIPTED_INDEX_DIR"].map(URL.init(fileURLWithPath:))

        if let sharedDataRoot = resolved.sharedDataRoot {
            return TranscriptedDataDirectories(
                meetingDirs: resolved.meetingDirs,
                dictationDirs: resolved.dictationDirs,
                timelineDirs: resolved.timelineDirs,
                indexDir: indexOverride ?? sharedDataRoot,
                resolutionSource: resolved.resolutionSource,
                legacyFallbackAppended: resolved.legacyFallbackAppended
            )
        }

        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let defaultIndex = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)

        return TranscriptedDataDirectories(
            meetingDirs: resolved.meetingDirs,
            dictationDirs: resolved.dictationDirs,
            timelineDirs: resolved.timelineDirs,
            indexDir: indexOverride ?? defaultIndex,
            resolutionSource: resolved.resolutionSource,
            legacyFallbackAppended: resolved.legacyFallbackAppended
        )
    }
}

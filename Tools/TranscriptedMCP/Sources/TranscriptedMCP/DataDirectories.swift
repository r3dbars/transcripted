import Foundation
import TranscriptedCaptureKit

struct TranscriptedDataDirectories {
    let meetingDirs: [URL]
    let dictationDirs: [URL]
    /// Writing day files. Empty only for hand-built values (tests) that pass
    /// no writing directory; `resolve()` always yields one.
    let writingDirs: [URL]
    let indexDir: URL
    let resolutionSource: CaptureLibraryResolutionSource
    let legacyFallbackAppended: Bool

    var meetingsDir: URL {
        meetingDirs[0]
    }

    var dictationsDir: URL {
        dictationDirs[0]
    }

    var watchedDirectories: [URL] {
        var seen: Set<String> = []
        var directories: [URL] = []

        for url in meetingDirs + dictationDirs + writingDirs {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            directories.append(url)
        }

        return directories
    }

    /// Directories the server creates when missing: meetings, dictations, and
    /// the index. The writing folder is left for the app to create (it owns
    /// the folder's 0700 mode), so a user who never turns Writing on never
    /// gets an empty `writing/` folder. A missing writing folder is still
    /// watched by the watcher's periodic rescan.
    var directoriesToCreate: [URL] {
        var seen: Set<String> = []
        var directories: [URL] = []

        for url in meetingDirs + dictationDirs + [indexDir] {
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
        writingDir: URL? = nil,
        indexDir: URL,
        resolutionSource: CaptureLibraryResolutionSource = .defaultCaptures,
        legacyFallbackAppended: Bool = false
    ) {
        self.meetingDirs = [meetingsDir]
        self.dictationDirs = [dictationsDir]
        self.writingDirs = writingDir.map { [$0] } ?? []
        self.indexDir = indexDir
        self.resolutionSource = resolutionSource
        self.legacyFallbackAppended = legacyFallbackAppended
    }

    init(
        meetingDirs: [URL],
        dictationDirs: [URL],
        writingDirs: [URL] = [],
        indexDir: URL,
        resolutionSource: CaptureLibraryResolutionSource = .defaultCaptures,
        legacyFallbackAppended: Bool = false
    ) {
        self.meetingDirs = meetingDirs
        self.dictationDirs = dictationDirs
        self.writingDirs = writingDirs
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
                writingDirs: resolved.writingDirs,
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
            writingDirs: resolved.writingDirs,
            indexDir: indexOverride ?? defaultIndex,
            resolutionSource: resolved.resolutionSource,
            legacyFallbackAppended: resolved.legacyFallbackAppended
        )
    }
}

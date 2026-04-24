import Foundation

struct TranscriptedDataDirectories {
    let meetingDirs: [URL]
    let dictationDirs: [URL]
    let indexDir: URL

    var meetingsDir: URL {
        meetingDirs[0]
    }

    var dictationsDir: URL {
        dictationDirs[0]
    }

    var watchedDirectories: [URL] {
        var seen: Set<String> = []
        var directories: [URL] = []

        for url in meetingDirs + dictationDirs {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            directories.append(url)
        }

        return directories
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> TranscriptedDataDirectories {
        resolve(
            environment: environment,
            fileManager: fileManager,
            homeDirectory: fileManager.homeDirectoryForCurrentUser
        )
    }

    static func resolve(
        environment: [String: String],
        fileManager: FileManager,
        homeDirectory home: URL
    ) -> TranscriptedDataDirectories {
        if let sharedPath = environment["TRANSCRIPTED_DATA_DIR"], !sharedPath.isEmpty {
            let sharedURL = URL(fileURLWithPath: sharedPath)
            let meetingsURL: URL
            let dictationsURL: URL
            if fileManager.fileExists(atPath: sharedURL.appendingPathComponent("meetings", isDirectory: true).path)
                || fileManager.fileExists(atPath: sharedURL.appendingPathComponent("dictations", isDirectory: true).path) {
                meetingsURL = sharedURL.appendingPathComponent("meetings", isDirectory: true)
                dictationsURL = sharedURL.appendingPathComponent("dictations", isDirectory: true)
            } else {
                meetingsURL = sharedURL
                dictationsURL = sharedURL
            }
            let indexURL = environment["TRANSCRIPTED_INDEX_DIR"].map(URL.init(fileURLWithPath:))
                ?? sharedURL
            return TranscriptedDataDirectories(
                meetingDirs: [meetingsURL],
                dictationDirs: [dictationsURL],
                indexDir: indexURL
            )
        }

        let transcriptedRoot = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
        let defaultCaptures = transcriptedRoot.appendingPathComponent("captures", isDirectory: true)
        let defaultMeetings = defaultCaptures.appendingPathComponent("meetings", isDirectory: true)
        let defaultDictations = defaultCaptures.appendingPathComponent("dictations", isDirectory: true)
        let defaultIndex = transcriptedRoot.appendingPathComponent("cache", isDirectory: true)

        let draftRoot = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Draft", isDirectory: true)

        let legacyDraftMeetings = draftRoot
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        let legacyDraftDictations = draftRoot
            .appendingPathComponent("dictations", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        let legacyShared = home
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)

        let meetingsOverride = environment["TRANSCRIPTED_MEETINGS_DIR"].map(URL.init(fileURLWithPath:))
        let dictationsOverride = environment["TRANSCRIPTED_DICTATIONS_DIR"].map(URL.init(fileURLWithPath:))
        let indexOverride = environment["TRANSCRIPTED_INDEX_DIR"].map(URL.init(fileURLWithPath:))

        let meetingDirs = meetingsOverride.map { [$0] }
            ?? captureDirectories(
                primary: defaultMeetings,
                legacyCandidates: [legacyDraftMeetings, legacyShared],
                fileManager: fileManager
            )
        let dictationDirs = dictationsOverride.map { [$0] }
            ?? captureDirectories(
                primary: defaultDictations,
                legacyCandidates: [legacyDraftDictations, legacyShared],
                fileManager: fileManager
            )

        return TranscriptedDataDirectories(
            meetingDirs: meetingDirs,
            dictationDirs: dictationDirs,
            indexDir: indexOverride ?? defaultIndex
        )
    }

    private static func captureDirectories(primary: URL, legacyCandidates: [URL], fileManager: FileManager) -> [URL] {
        var directories = [primary]
        var seen = Set([primary.standardizedFileURL.path])

        for candidate in legacyCandidates where directoryHasMarkdownFiles(candidate, fileManager: fileManager) {
            let path = candidate.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            directories.append(candidate)
        }

        return directories
    }

    private static func directoryHasMarkdownFiles(_ directory: URL, fileManager: FileManager) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return contents.contains { url in
            guard url.pathExtension == "md",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }
}

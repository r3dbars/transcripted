import Foundation

struct TranscriptedDataDirectories {
    let meetingsDir: URL
    let dictationsDir: URL
    let indexDir: URL

    var watchedDirectories: [URL] {
        var seen: Set<String> = []
        var directories: [URL] = []

        for url in [meetingsDir, dictationsDir] {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            directories.append(url)
        }

        return directories
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
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
                meetingsDir: meetingsURL,
                dictationsDir: dictationsURL,
                indexDir: indexURL
            )
        }

        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
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
        let currentTranscriptedCapturesExist = fileManager.fileExists(atPath: defaultMeetings.path)
            || fileManager.fileExists(atPath: defaultDictations.path)

        let legacyDraftCapturesExist = fileManager.fileExists(atPath: legacyDraftMeetings.path)
            || fileManager.fileExists(atPath: legacyDraftDictations.path)

        let useLegacyDraft = meetingsOverride == nil
            && dictationsOverride == nil
            && !currentTranscriptedCapturesExist
            && legacyDraftCapturesExist
        let useLegacyShared = meetingsOverride == nil
            && dictationsOverride == nil
            && !currentTranscriptedCapturesExist
            && !legacyDraftCapturesExist
            && fileManager.fileExists(atPath: legacyShared.path)

        return TranscriptedDataDirectories(
            meetingsDir: meetingsOverride ?? (useLegacyDraft ? legacyDraftMeetings : (useLegacyShared ? legacyShared : defaultMeetings)),
            dictationsDir: dictationsOverride ?? (useLegacyDraft ? legacyDraftDictations : (useLegacyShared ? legacyShared : defaultDictations)),
            indexDir: indexOverride ?? defaultIndex
        )
    }
}

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
        fileManager: FileManager = .default
    ) -> TranscriptedDataDirectories {
        if let sharedPath = environment["TRANSCRIPTED_DATA_DIR"], !sharedPath.isEmpty {
            let sharedURL = URL(fileURLWithPath: sharedPath)
            let indexURL = environment["TRANSCRIPTED_INDEX_DIR"].map(URL.init(fileURLWithPath:)) ?? sharedURL
            return TranscriptedDataDirectories(
                meetingsDir: sharedURL,
                dictationsDir: sharedURL,
                indexDir: indexURL
            )
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let draftRoot = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Draft", isDirectory: true)

        let defaultMeetings = draftRoot
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        let defaultDictations = draftRoot
            .appendingPathComponent("dictations", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        let legacyShared = home
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)

        let meetingsOverride = environment["TRANSCRIPTED_MEETINGS_DIR"].map(URL.init(fileURLWithPath:))
        let dictationsOverride = environment["TRANSCRIPTED_DICTATIONS_DIR"].map(URL.init(fileURLWithPath:))
        let indexOverride = environment["TRANSCRIPTED_INDEX_DIR"].map(URL.init(fileURLWithPath:))

        let useLegacy = meetingsOverride == nil
            && dictationsOverride == nil
            && !fileManager.fileExists(atPath: defaultMeetings.path)
            && fileManager.fileExists(atPath: legacyShared.path)

        return TranscriptedDataDirectories(
            meetingsDir: meetingsOverride ?? (useLegacy ? legacyShared : defaultMeetings),
            dictationsDir: dictationsOverride ?? (useLegacy ? legacyShared : defaultDictations),
            indexDir: indexOverride ?? (meetingsOverride ?? (useLegacy ? legacyShared : defaultMeetings))
        )
    }
}

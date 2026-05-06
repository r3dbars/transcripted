import Foundation

private struct AppDirectoryManifest: Decodable {
    let version: Int
    let captureLibraryDirectory: String
    let meetingsDirectory: String
    let dictationsDirectory: String
}

private struct ConfiguredCaptureDirectories {
    let meetings: URL
    let dictations: URL
}

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

    init(meetingsDir: URL, dictationsDir: URL, indexDir: URL) {
        self.meetingDirs = [meetingsDir]
        self.dictationDirs = [dictationsDir]
        self.indexDir = indexDir
    }

    init(meetingDirs: [URL], dictationDirs: [URL], indexDir: URL) {
        self.meetingDirs = meetingDirs
        self.dictationDirs = dictationDirs
        self.indexDir = indexDir
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

        let appConfiguredCaptureDirectories = configuredCaptureDirectories(
            homeDirectory: home,
            fileManager: fileManager
        )
        let meetingsOverride = environment["TRANSCRIPTED_MEETINGS_DIR"].map(URL.init(fileURLWithPath:))
        let dictationsOverride = environment["TRANSCRIPTED_DICTATIONS_DIR"].map(URL.init(fileURLWithPath:))
        let indexOverride = environment["TRANSCRIPTED_INDEX_DIR"].map(URL.init(fileURLWithPath:))
        let meetingDirs = meetingsOverride.map { [$0] }
            ?? appConfiguredCaptureDirectories.map {
                captureDirectories(
                    primary: $0.meetings,
                    legacyCandidates: [legacyDraftMeetings, legacyShared],
                    fileManager: fileManager
                )
            }
            ?? captureDirectories(
                primary: defaultMeetings,
                legacyCandidates: [legacyDraftMeetings, legacyShared],
                fileManager: fileManager
            )
        let dictationDirs = dictationsOverride.map { [$0] }
            ?? appConfiguredCaptureDirectories.map {
                captureDirectories(
                    primary: $0.dictations,
                    legacyCandidates: [legacyDraftDictations, legacyShared],
                    fileManager: fileManager
                )
            }
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

        for candidate in legacyCandidates where directoryHasCaptureMarkdownFiles(candidate, fileManager: fileManager) {
            let path = candidate.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            directories.append(candidate)
        }

        return directories
    }

    private static func directoryHasCaptureMarkdownFiles(_ directory: URL, fileManager: FileManager) -> Bool {
        let enumerationRoot = directory.resolvingSymlinksInPath().standardizedFileURL
        guard let contents = try? fileManager.contentsOfDirectory(
            at: enumerationRoot,
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
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return false
            }
            return looksLikeCaptureMarkdown(url)
        }
    }

    private static func looksLikeCaptureMarkdown(_ url: URL) -> Bool {
        let filename = url.deletingPathExtension().lastPathComponent
        if filename.hasPrefix("Dictations_") {
            return true
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }

        return content.hasPrefix("---\n") && content.contains("\n---\n")
    }

    private static func configuredCaptureDirectories(
        homeDirectory home: URL,
        fileManager: FileManager
    ) -> ConfiguredCaptureDirectories? {
        manifestCaptureDirectories(homeDirectory: home, fileManager: fileManager)
            ?? appPreferenceCaptureDirectories(homeDirectory: home)
    }

    private static func manifestCaptureDirectories(
        homeDirectory home: URL,
        fileManager: FileManager
    ) -> ConfiguredCaptureDirectories? {
        let manifestURL = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
            .appendingPathComponent("mcp-directories.json", isDirectory: false)

        guard fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(AppDirectoryManifest.self, from: data),
              manifest.version >= 1,
              let meetings = validatedConfiguredDirectory(manifest.meetingsDirectory, homeDirectory: home),
              let dictations = validatedConfiguredDirectory(manifest.dictationsDirectory, homeDirectory: home) else {
            return nil
        }

        return ConfiguredCaptureDirectories(meetings: meetings, dictations: dictations)
    }

    private static func appPreferenceCaptureDirectories(homeDirectory home: URL) -> ConfiguredCaptureDirectories? {
        for domain in appPreferenceDomains {
            let preferenceURL = home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Preferences", isDirectory: true)
                .appendingPathComponent("\(domain).plist", isDirectory: false)

            guard let data = try? Data(contentsOf: preferenceURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let values = plist as? [String: Any],
                  let rawPath = values["transcriptSaveLocation"] as? String,
                  let captureLibrary = validatedConfiguredDirectory(rawPath, homeDirectory: home) else {
                continue
            }

            return ConfiguredCaptureDirectories(
                meetings: captureLibrary.appendingPathComponent("meetings", isDirectory: true),
                dictations: captureLibrary.appendingPathComponent("dictations", isDirectory: true)
            )
        }

        return nil
    }

    private static var appPreferenceDomains: [String] {
        [
            "com.justinbetker.draft",
            "app.transcripted.Transcripted",
        ]
    }

    private static func validatedConfiguredDirectory(_ rawPath: String, homeDirectory home: URL) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            return nil
        }

        let directory = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        guard directory.path != "/", !directory.pathComponents.contains("..") else {
            return nil
        }

        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedHome = home.resolvingSymlinksInPath().standardizedFileURL
        let isUnderHome = resolvedDirectory.path == resolvedHome.path
            || resolvedDirectory.path.hasPrefix(resolvedHome.path + "/")
        let forbiddenPrefixes = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private"]
        let isForbidden = forbiddenPrefixes.contains { prefix in
            resolvedDirectory.path == prefix || resolvedDirectory.path.hasPrefix(prefix + "/")
        }

        guard !isForbidden || isUnderHome else {
            return nil
        }

        return directory
    }
}

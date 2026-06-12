import Foundation

private struct CaptureDirectoryManifest: Decodable {
    let version: Int
    let captureLibraryDirectory: String
    let meetingsDirectory: String
    let dictationsDirectory: String
}

private struct ConfiguredCaptureDirectories {
    let meetings: URL
    let dictations: URL
}

/// Resolved capture-library locations for meetings and dictations.
public struct ResolvedCaptureDirectories {
    public let meetingDirs: [URL]
    public let dictationDirs: [URL]
    /// Set when resolution used an explicit shared data directory
    /// (a `--data-dir` style argument or `TRANSCRIPTED_DATA_DIR`).
    public let sharedDataRoot: URL?

    public init(meetingDirs: [URL], dictationDirs: [URL], sharedDataRoot: URL? = nil) {
        self.meetingDirs = meetingDirs
        self.dictationDirs = dictationDirs
        self.sharedDataRoot = sharedDataRoot
    }
}

/// Shared capture-library resolution for the standalone tools.
///
/// Resolution order:
/// 1. explicit shared data dir argument, then `TRANSCRIPTED_DATA_DIR`
///    (uses `meetings/` + `dictations/` subfolders when either exists)
/// 2. explicit per-kind argument, then `TRANSCRIPTED_MEETINGS_DIR` /
///    `TRANSCRIPTED_DICTATIONS_DIR`
/// 3. the app-selected capture library (`mcp-directories.json` manifest, then
///    the `transcriptSaveLocation` preference)
/// 4. the default Transcripted captures folders, followed by legacy Draft
///    exports and `~/Documents/Transcripted` when those contain capture
///    Markdown
public enum CaptureLibraryResolver {
    public static func resolve(
        dataDir: String? = nil,
        meetingsDir: String? = nil,
        dictationsDir: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) -> ResolvedCaptureDirectories {
        let explicitShared = dataDir.flatMap { $0.isEmpty ? nil : $0 }
        let environmentShared = environment["TRANSCRIPTED_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        if let sharedPath = explicitShared ?? environmentShared {
            let sharedURL = URL(fileURLWithPath: sharedPath)
            let sharedMeetings = sharedURL.appendingPathComponent("meetings", isDirectory: true)
            let sharedDictations = sharedURL.appendingPathComponent("dictations", isDirectory: true)
            if fileManager.fileExists(atPath: sharedMeetings.path)
                || fileManager.fileExists(atPath: sharedDictations.path) {
                return ResolvedCaptureDirectories(
                    meetingDirs: [sharedMeetings],
                    dictationDirs: [sharedDictations],
                    sharedDataRoot: sharedURL
                )
            }
            return ResolvedCaptureDirectories(
                meetingDirs: [sharedURL],
                dictationDirs: [sharedURL],
                sharedDataRoot: sharedURL
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

        let appConfigured = configuredCaptureDirectories(
            homeDirectory: home,
            fileManager: fileManager
        )
        let meetingsOverride = meetingsDir.map(URL.init(fileURLWithPath:))
            ?? environment["TRANSCRIPTED_MEETINGS_DIR"].map(URL.init(fileURLWithPath:))
        let dictationsOverride = dictationsDir.map(URL.init(fileURLWithPath:))
            ?? environment["TRANSCRIPTED_DICTATIONS_DIR"].map(URL.init(fileURLWithPath:))

        let meetingDirs = meetingsOverride.map { [$0] }
            ?? appConfigured.map {
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
            ?? appConfigured.map {
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

        return ResolvedCaptureDirectories(
            meetingDirs: meetingDirs,
            dictationDirs: dictationDirs,
            sharedDataRoot: nil
        )
    }

    private static func captureDirectories(primary: URL, legacyCandidates: [URL], fileManager: FileManager) -> [URL] {
        var directories = [primary]
        var seen = Set([primary.standardizedFileURL.path])

        for candidate in legacyCandidates
        where CaptureMarkdown.directoryHasCaptureMarkdownFiles(candidate, fileManager: fileManager) {
            let path = candidate.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            directories.append(candidate)
        }

        return directories
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
              let manifest = try? JSONDecoder().decode(CaptureDirectoryManifest.self, from: data),
              manifest.version >= 1,
              let captureLibrary = validatedConfiguredDirectory(manifest.captureLibraryDirectory, homeDirectory: home),
              let meetings = validatedConfiguredDirectory(manifest.meetingsDirectory, homeDirectory: home),
              let dictations = validatedConfiguredDirectory(manifest.dictationsDirectory, homeDirectory: home),
              isManifestDirectory(meetings, named: "meetings", under: captureLibrary),
              isManifestDirectory(dictations, named: "dictations", under: captureLibrary) else {
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

    private static func isManifestDirectory(_ directory: URL, named name: String, under captureLibrary: URL) -> Bool {
        let expected = captureLibrary
            .appendingPathComponent(name, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let actual = directory
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return actual.path == expected.path
    }
}

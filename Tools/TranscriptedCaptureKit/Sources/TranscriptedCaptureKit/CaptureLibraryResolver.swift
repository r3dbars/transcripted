import Foundation

private struct CaptureDirectoryManifest: Decodable {
    let version: Int
    let captureLibraryDirectory: String
    let meetingsDirectory: String
    let dictationsDirectory: String
    /// Optional: app builds from before Writing never write it. When absent,
    /// the writing folder is `<captureLibraryDirectory>/writing`.
    let writingDirectory: String?
}

private struct ConfiguredCaptureDirectories {
    let meetings: URL
    let dictations: URL
    let writing: URL
    let source: CaptureLibraryResolutionSource
}

/// Which resolution rule selected the capture directories. Explicit
/// `--data-dir` / `--meetings-dir` style arguments report the same tier as
/// their environment-variable equivalents.
public enum CaptureLibraryResolutionSource: String, Codable, Sendable {
    case envDataDir = "env_data_dir"
    case envKindDirs = "env_kind_dirs"
    case appManifest = "app_manifest"
    case appPreference = "app_preference"
    case defaultCaptures = "default"
}

/// Resolved capture-library locations for meetings, dictations, and writing.
public struct ResolvedCaptureDirectories {
    public let meetingDirs: [URL]
    public let dictationDirs: [URL]
    /// Writing day files (`Writing_<date>.md`). `resolve()` always yields one
    /// directory; it is empty only when a caller builds this value by hand.
    public let writingDirs: [URL]
    /// Set when resolution used an explicit shared data directory
    /// (a `--data-dir` style argument or `TRANSCRIPTED_DATA_DIR`).
    public let sharedDataRoot: URL?
    /// Which resolution rule selected the directories above.
    public let resolutionSource: CaptureLibraryResolutionSource
    /// True when legacy fallback directories (Draft exports,
    /// `~/Documents/Transcripted`) were appended after the primary directory.
    public let legacyFallbackAppended: Bool

    public init(
        meetingDirs: [URL],
        dictationDirs: [URL],
        writingDirs: [URL] = [],
        sharedDataRoot: URL? = nil,
        resolutionSource: CaptureLibraryResolutionSource = .defaultCaptures,
        legacyFallbackAppended: Bool = false
    ) {
        self.meetingDirs = meetingDirs
        self.dictationDirs = dictationDirs
        self.writingDirs = writingDirs
        self.sharedDataRoot = sharedDataRoot
        self.resolutionSource = resolutionSource
        self.legacyFallbackAppended = legacyFallbackAppended
    }
}

/// Shared capture-library resolution for the standalone tools.
///
/// Resolution order:
/// 1. explicit shared data dir argument, then `TRANSCRIPTED_DATA_DIR`
///    (uses `meetings/` + `dictations/` + `writing/` subfolders when any of
///    them exists; otherwise every kind reads the shared root itself)
/// 2. explicit per-kind argument, then `TRANSCRIPTED_MEETINGS_DIR` /
///    `TRANSCRIPTED_DICTATIONS_DIR` / `TRANSCRIPTED_WRITING_DIR`
/// 3. the app-selected capture library (`mcp-directories.json` manifest, then
///    the `transcriptSaveLocation` preference)
/// 4. the default Transcripted captures folders, followed by legacy Draft
///    exports and `~/Documents/Transcripted` when those contain capture
///    Markdown (meetings and dictations only; writing has no legacy location)
public enum CaptureLibraryResolver {
    public static func resolve(
        dataDir: String? = nil,
        meetingsDir: String? = nil,
        dictationsDir: String? = nil,
        writingDir: String? = nil,
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
            let sharedWriting = sharedURL.appendingPathComponent("writing", isDirectory: true)
            if fileManager.fileExists(atPath: sharedMeetings.path)
                || fileManager.fileExists(atPath: sharedDictations.path)
                || fileManager.fileExists(atPath: sharedWriting.path) {
                return ResolvedCaptureDirectories(
                    meetingDirs: [sharedMeetings],
                    dictationDirs: [sharedDictations],
                    writingDirs: [sharedWriting],
                    sharedDataRoot: sharedURL,
                    resolutionSource: .envDataDir
                )
            }
            // Flat shared folder: every kind reads the root. Readers tell the
            // kinds apart by filename prefix and `capture_type`, so a
            // `Writing_` file here must never be treated as a meeting.
            return ResolvedCaptureDirectories(
                meetingDirs: [sharedURL],
                dictationDirs: [sharedURL],
                writingDirs: [sharedURL],
                sharedDataRoot: sharedURL,
                resolutionSource: .envDataDir
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
        let defaultWriting = defaultCaptures.appendingPathComponent("writing", isDirectory: true)

        let legacy = legacyCaptureDirectories(homeDirectory: home)
        let legacyDraftMeetings = legacy.draftMeetings
        let legacyDraftDictations = legacy.draftDictations
        let legacyShared = legacy.sharedRoot

        let appConfigured = configuredCaptureDirectories(
            homeDirectory: home,
            fileManager: fileManager
        )
        let meetingsOverride = meetingsDir.map(URL.init(fileURLWithPath:))
            ?? environment["TRANSCRIPTED_MEETINGS_DIR"].map(URL.init(fileURLWithPath:))
        let dictationsOverride = dictationsDir.map(URL.init(fileURLWithPath:))
            ?? environment["TRANSCRIPTED_DICTATIONS_DIR"].map(URL.init(fileURLWithPath:))
        // Empty values are ignored (as for TRANSCRIPTED_DATA_DIR) so an exported
        // but blank variable can't resolve to the process working directory.
        let writingOverride = writingDir.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? environment["TRANSCRIPTED_WRITING_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

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
        // Writing is new with this app generation, so there is no Draft-era or
        // `~/Documents/Transcripted` location to fall back to.
        let writingDirs = [writingOverride ?? appConfigured?.writing ?? defaultWriting]

        // When only some kinds are overridden, the others still resolve through
        // the manifest/preference/default chain; report the override tier as
        // the winning rule since it took precedence for the kinds it covers.
        let resolutionSource: CaptureLibraryResolutionSource
        if meetingsOverride != nil || dictationsOverride != nil || writingOverride != nil {
            resolutionSource = .envKindDirs
        } else if let appConfigured {
            resolutionSource = appConfigured.source
        } else {
            resolutionSource = .defaultCaptures
        }

        // Primary resolution always yields one directory per kind; anything
        // extra came from the legacy candidates.
        let legacyFallbackAppended = meetingDirs.count > 1 || dictationDirs.count > 1

        return ResolvedCaptureDirectories(
            meetingDirs: meetingDirs,
            dictationDirs: dictationDirs,
            writingDirs: writingDirs,
            sharedDataRoot: nil,
            resolutionSource: resolutionSource,
            legacyFallbackAppended: legacyFallbackAppended
        )
    }

    /// The legacy Draft-era and pre-relocation locations `resolve()` falls
    /// back to (in order) after the current default capture-library folders,
    /// when those legacy folders contain capture Markdown.
    ///
    /// Exposed publicly so other tools that need this exact legacy layout —
    /// currently `TranscriptedQA`'s `QADataDirectories.inferBaseLayout`, which
    /// infers a sibling state/log layout from a caller-supplied `--path` —
    /// derive it from this one place instead of re-declaring the Draft/legacy
    /// folder names by hand. That duplication is exactly the kind of drift
    /// that made TranscriptedQA's copy fall out of sync with this resolver's
    /// list before (see `a5a766cc`, `b2b54268`).
    public struct LegacyCaptureDirectories {
        public let draftRoot: URL
        public let draftMeetings: URL
        public let draftDictations: URL
        public let sharedRoot: URL
    }

    public static func legacyCaptureDirectories(homeDirectory: URL) -> LegacyCaptureDirectories {
        let draftRoot = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Draft", isDirectory: true)
        let draftMeetings = draftRoot
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        let draftDictations = draftRoot
            .appendingPathComponent("dictations", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        let sharedRoot = homeDirectory
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)

        return LegacyCaptureDirectories(
            draftRoot: draftRoot,
            draftMeetings: draftMeetings,
            draftDictations: draftDictations,
            sharedRoot: sharedRoot
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

        // The writing key is optional (older app builds don't write it), but a
        // present one gets the same validation as the other kinds: an unsafe or
        // misplaced writing path rejects the whole manifest, not just that key.
        let writing: URL
        if let rawWriting = manifest.writingDirectory {
            guard let validated = validatedConfiguredDirectory(rawWriting, homeDirectory: home),
                  isManifestDirectory(validated, named: "writing", under: captureLibrary) else {
                return nil
            }
            writing = validated
        } else {
            writing = captureLibrary.appendingPathComponent("writing", isDirectory: true)
        }

        return ConfiguredCaptureDirectories(
            meetings: meetings,
            dictations: dictations,
            writing: writing,
            source: .appManifest
        )
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
                dictations: captureLibrary.appendingPathComponent("dictations", isDirectory: true),
                writing: captureLibrary.appendingPathComponent("writing", isDirectory: true),
                source: .appPreference
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

    // Delegates to the shared save-path safety predicate — see
    // CaptureLibraryPathSafety.swift's header comment for why this rule lives
    // in exactly one file, vendored into this target, the app target
    // (TranscriptedStoragePaths), and TranscriptedCore (RecordingValidator).
    private static func validatedConfiguredDirectory(_ rawPath: String, homeDirectory home: URL) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        // Security: check the RAW string before constructing a URL.
        // `URL(fileURLWithPath:)` silently resolves a relative string against
        // the process working directory, which would turn a tampered relative
        // preference value into an absolute path that then passes the
        // absolute-path check below.
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            return nil
        }

        let directory = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        guard CaptureLibraryPathSafety.evaluate(directory, homeDirectory: home) == .safe else {
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

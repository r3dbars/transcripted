import Foundation

/// Resolves the best on-disk target for an app-owned capture artifact whose
/// recorded URL may have drifted since it was captured.
///
/// Home / meeting rows (and the preview, summary notices, copy/export, and audio
/// playback paths) hold the file URLs captured when the dashboard was last
/// *scanned*. Background work moves those files afterwards: the post-save
/// restyle renames a meeting transcript (and its `audio/<stem>_audio/` bundle),
/// a rename from the preview moves the transcript + summary sidecar, and
/// retained audio is recompressed from WAV to M4A. By the time the user opens a
/// row's overflow menu (or hits "Open Markdown" / plays audio), the recorded URL
/// can be stale, so a raw `NSWorkspace.activateFileViewerSelecting([url])` /
/// `NSWorkspace.open(url)` / `NSSound(contentsOf: url)` on a missing path
/// silently no-ops (the "Show … in Finder does nothing / Open does nothing /
/// works on one machine but not another" reports that were patched one control
/// at a time in #1126, #1131, #1134).
///
/// This is the single resolver every own-file access on the Home/meeting surface
/// routes through. It fails *loud*: when nothing on disk can satisfy the request
/// it reports `.unavailable` / `nil` so the caller surfaces an error instead of a
/// dead click.
///
/// Two resolution modes, because the right fallback differs by intent:
///
/// - ``resolveForReveal(candidateURLs:fileManager:)`` — for "reveal in Finder".
///   Revealing an enclosing folder beats a dead click, so it falls back all the
///   way to the first enclosing directory that still exists.
///     1. Reveal the candidate files that still exist.
///     2. Otherwise re-match by stem in the same directory (a WAV that became an
///        M4A keeps its `system_audio` / `microphone` stem).
///     3. Otherwise fall back to the first enclosing directory that still exists.
///     4. Otherwise `.unavailable`.
///
/// - ``resolveExistingFile(candidateURLs:fileManager:)`` — for "open / read /
///   play / re-transcribe". The caller needs a real *file* it can hand to
///   `NSWorkspace.open`, `String(contentsOf:)`, or `NSSound(contentsOf:)`, so it
///   must NOT fall back to a directory.
///     1. Use the candidate that still exists (must be a regular file).
///     2. Otherwise stem-rematch to a sibling *regular file*.
///     3. Otherwise `nil`.
enum OwnFileResolver {
    enum RevealOutcome: Equatable {
        /// Pass these URLs straight to `activateFileViewerSelecting(_:)`.
        case reveal([URL])
        /// Nothing on disk can be revealed; the caller should surface an error.
        case unavailable
    }

    // MARK: - Reveal-in-Finder

    static func resolveForReveal(
        candidateURLs: [URL],
        fileManager: FileManager = .default
    ) -> RevealOutcome {
        let candidates = sanitized(candidateURLs)
        guard !candidates.isEmpty else { return .unavailable }

        // 1. Direct hits — the recorded paths still exist.
        let existing = uniqued(candidates.filter { fileManager.fileExists(atPath: $0.path) })
        if !existing.isEmpty {
            return .reveal(existing)
        }

        // 2. Stem-tolerant rematch. Handles retained audio that was recompressed
        //    from `.wav` to `.m4a` after the row was scanned: same stem, new
        //    extension, same directory.
        let rematched = uniqued(candidates.compactMap { candidate in
            firstSibling(matchingStemOf: candidate, in: fileManager, requireRegularFile: false)
        })
        if !rematched.isEmpty {
            return .reveal(rematched)
        }

        // 3. Fall back to the first enclosing directory that still exists. For a
        //    renamed transcript this is the meetings folder; for audio it is the
        //    `<stem>_audio` bundle. Revealing the folder beats a dead click.
        for candidate in candidates {
            let directory = candidate.deletingLastPathComponent()
            if isDirectory(directory, fileManager: fileManager) {
                return .reveal([directory])
            }
        }

        return .unavailable
    }

    // MARK: - Open / read / play

    /// Resolves a single candidate set to an existing regular file, tolerant to a
    /// stem-only rename (WAV→M4A recompression). Returns `nil` when no regular
    /// file backs any candidate, so the caller can surface an error instead of
    /// opening/reading/playing a path that silently does nothing.
    static func resolveExistingFile(
        candidateURLs: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = sanitized(candidateURLs)
        guard !candidates.isEmpty else { return nil }

        // 1. Direct hit — the recorded path is still a regular file.
        if let direct = candidates.first(where: { isRegularFile($0, fileManager: fileManager) }) {
            return direct
        }

        // 2. Stem-tolerant rematch to a sibling regular file.
        for candidate in candidates {
            if let sibling = firstSibling(matchingStemOf: candidate, in: fileManager, requireRegularFile: true) {
                return sibling
            }
        }

        return nil
    }

    /// Resolves each candidate independently to an existing regular file,
    /// dropping the ones nothing backs. Order-preserving and de-duplicated. Use
    /// when several files (e.g. mic + system audio) must each resolve before an
    /// operation can proceed.
    static func resolveExistingFiles(
        candidateURLs: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        uniqued(sanitized(candidateURLs).compactMap { candidate in
            resolveExistingFile(candidateURLs: [candidate], fileManager: fileManager)
        })
    }

    // MARK: - Helpers

    private static func firstSibling(
        matchingStemOf candidate: URL,
        in fileManager: FileManager,
        requireRegularFile: Bool
    ) -> URL? {
        let directory = candidate.deletingLastPathComponent()
        let stem = candidate.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty,
              let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }
        return contents
            .filter { $0.deletingPathExtension().lastPathComponent == stem }
            .filter { !requireRegularFile || isRegularFile($0, fileManager: fileManager) }
            .sorted { lhs, rhs in
                lhs.pathExtension.localizedCaseInsensitiveCompare(rhs.pathExtension) == .orderedAscending
            }
            .first
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    private static func sanitized(_ urls: [URL]) -> [URL] {
        urls.filter { !$0.path.isEmpty }
    }

    private static func uniqued(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.resolvingSymlinksInPath().path
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result
    }
}

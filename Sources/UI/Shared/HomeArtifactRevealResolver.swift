import Foundation

/// Resolves the best "reveal in Finder" target for a Home capture artifact.
///
/// Home rows hold the file URLs captured when the dashboard was last *scanned*.
/// Background work moves those files afterwards — the post-save restyle renames
/// a meeting transcript (and its `audio/<stem>_audio/` bundle), and retained
/// audio is recompressed from WAV to M4A. By the time the user opens the row's
/// overflow menu, the recorded URL can be stale, so a raw
/// `NSWorkspace.activateFileViewerSelecting([url])` on a missing path silently
/// no-ops (the "Show … in Finder does nothing / works on one machine but not
/// another" reports).
///
/// This resolver fails *loud* instead of silent:
///   1. Reveal the candidate files that still exist.
///   2. Otherwise re-match by stem in the same directory (a WAV that became an
///      M4A keeps its `system_audio` / `microphone` stem).
///   3. Otherwise fall back to the first enclosing directory that still exists.
///   4. Otherwise report `.unavailable` so the caller can surface an error.
enum HomeArtifactRevealResolver {
    enum Outcome: Equatable {
        /// Pass these URLs straight to `activateFileViewerSelecting(_:)`.
        case reveal([URL])
        /// Nothing on disk can be revealed; the caller should surface an error.
        case unavailable
    }

    static func resolve(
        candidateURLs: [URL],
        fileManager: FileManager = .default
    ) -> Outcome {
        let candidates = candidateURLs.filter { !$0.path.isEmpty }
        guard !candidates.isEmpty else { return .unavailable }

        // 1. Direct hits — the recorded paths still exist.
        let existing = uniqued(candidates.filter { fileManager.fileExists(atPath: $0.path) })
        if !existing.isEmpty {
            return .reveal(existing)
        }

        // 2. Stem-tolerant rematch. Handles retained audio that was recompressed
        //    from `.wav` to `.m4a` after the row was scanned: same stem, new
        //    extension, same directory.
        var rematched: [URL] = []
        for candidate in candidates {
            let directory = candidate.deletingLastPathComponent()
            let stem = candidate.deletingPathExtension().lastPathComponent
            if let sibling = firstSibling(named: stem, in: directory, fileManager: fileManager) {
                rematched.append(sibling)
            }
        }
        let uniqueRematched = uniqued(rematched)
        if !uniqueRematched.isEmpty {
            return .reveal(uniqueRematched)
        }

        // 3. Fall back to the first enclosing directory that still exists. For a
        //    renamed transcript this is the meetings folder; for audio it is the
        //    `<stem>_audio` bundle. Revealing the folder beats a dead click.
        for candidate in candidates {
            let directory = candidate.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return .reveal([directory])
            }
        }

        return .unavailable
    }

    private static func firstSibling(
        named stem: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL? {
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
            .sorted { lhs, rhs in
                lhs.pathExtension.localizedCaseInsensitiveCompare(rhs.pathExtension) == .orderedAscending
            }
            .first
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

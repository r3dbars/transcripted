// CaptureLibraryPathSafety.swift
//
// SINGLE SOURCE: this is the one real file. Two git symlinks point at it, so
// the other build units compile the very same bytes:
//
//   - Sources/Support/CaptureLibraryPathSafety.swift (app target, raw `swiftc`)
//   - Tools/TranscriptedCaptureKit/Sources/TranscriptedCaptureKit/CaptureLibraryPathSafety.swift
//     (TranscriptedCaptureKit, SwiftPM follows symlinks)
//
// Edit only this file. The three build units can't drift because there is
// nothing to drift. The real file lives in TranscriptedCore on purpose: the
// deps build copies that tree with `ditto` and the staleness checks use
// `find -type f`, so a symlink there would dangle or go unnoticed. A checkout
// with `core.symlinks=false` turns the two links into text files and fails to
// compile; fix it with `git config core.symlinks true` and a re-checkout.
//
// This is the single, dependency-free (pure Foundation) definition of "is this
// filesystem path safe to use as a Transcripted capture-library / meeting
// save-path root?". `CaptureLibraryPathSafetyTests` in TranscriptedCaptureKit
// pins its behavior.
//
// Must remain pure Foundation with no other imports: it compiles directly
// into build units with different linker/framework setups and must not
// require any framework beyond what all three already link.

import Foundation

/// Whether a candidate directory URL is safe to use as a capture-library (or
/// legacy transcript save-path) root.
enum CaptureLibraryPathSafety {
    /// System directories that must never be used as a capture-library root,
    /// with an escape hatch for paths under the user's resolved home
    /// directory — symlink resolution can land a legitimate home path under a
    /// forbidden prefix (e.g. `/private` for `/var`-based homes), and that
    /// must stay allowed.
    static let forbiddenSystemPrefixes = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private"]

    enum Verdict: Equatable {
        case safe
        case notAbsolutePath
        case containsParentTraversal
        case isRootPath
        case forbiddenSystemPath(String)
    }

    /// Evaluates whether `url` is safe to use as a capture-library root.
    ///
    /// Checks `..` traversal components on the RAW path before symlink
    /// resolution: after `resolvingSymlinksInPath()` those components are
    /// already normalized away and would never appear in `pathComponents`,
    /// which would make a post-resolution check dead code. Symlinks are then
    /// resolved before the forbidden-prefix check so a symlink pointing at
    /// e.g. `/System` cannot bypass it.
    static func evaluate(
        _ url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Verdict {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            return .notAbsolutePath
        }

        if url.pathComponents.contains("..") {
            return .containsParentTraversal
        }

        let resolvedCandidate = url.standardizedFileURL.resolvingSymlinksInPath()
        if resolvedCandidate.path == "/" {
            return .isRootPath
        }

        let resolvedHome = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        let isUnderHome = resolvedCandidate.path == resolvedHome.path
            || resolvedCandidate.path.hasPrefix(resolvedHome.path + "/")

        if !isUnderHome {
            for prefix in forbiddenSystemPrefixes {
                if resolvedCandidate.path == prefix || resolvedCandidate.path.hasPrefix(prefix + "/") {
                    return .forbiddenSystemPath(prefix)
                }
            }
        }

        return .safe
    }

    /// Convenience boolean form for call sites that don't need the rejection reason.
    static func isSafe(
        _ url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        evaluate(url, homeDirectory: homeDirectory) == .safe
    }
}

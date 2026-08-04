// CaptureLibraryPathSafety.swift
//
// The single, dependency-free (pure Foundation) definition of "is this
// filesystem path safe to use as a Transcripted capture-library / meeting
// save-path root?" Three independent build units need this exact rule and
// cannot share it through a normal module import, since each compiles in
// isolation with a different dependency graph:
//
//   - the app target (this file, compiled directly by build.sh)
//   - the TranscriptedCore SPM target, which needs it for
//     `Sources/TranscriptedCore/Services/RecordingValidator.swift`
//   - the TranscriptedCaptureKit SPM target, which needs it for
//     `Tools/TranscriptedCaptureKit/Sources/TranscriptedCaptureKit/CaptureLibraryResolver.swift`
//
// This file is the canonical copy. It is vendored into the other two build
// units via a real symlink checked into git:
//
//   - Sources/TranscriptedCore/Services/CaptureLibraryPathSafety.swift
//   - Tools/TranscriptedCaptureKit/Sources/TranscriptedCaptureKit/CaptureLibraryPathSafety.swift
//
// Both symlinks resolve correctly for `swift build`/`swift test`, which
// operate directly on this checkout. `scripts/entrypoints/build-deps.sh`
// additionally materializes a real (non-symlink) copy inside its isolated
// `$DEPS_BUILD` scratch tree immediately after it ditto-copies
// `Sources/TranscriptedCore` there, because that copy only includes the
// TranscriptedCore subtree and would otherwise leave the Core-side symlink
// dangling — see the comment next to that `cp` call for details.
//
// Edit ONLY this file. The two vendored copies pick up the change
// automatically (they are the same inode via symlink); the isolated
// build-deps.sh copy picks it up on its next `cp`. Do not let the vendored
// copies diverge from this one — that is exactly the "three hand-maintained
// copies of one safety rule" drift this file exists to prevent.
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

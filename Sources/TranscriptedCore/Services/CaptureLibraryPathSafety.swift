// CaptureLibraryPathSafety.swift
//
// SYNCED COPY — this exact file exists byte-identically in three places:
//
//   - Sources/Support/CaptureLibraryPathSafety.swift (this file, the app target)
//   - Sources/TranscriptedCore/Services/CaptureLibraryPathSafety.swift (TranscriptedCore)
//   - Tools/TranscriptedCaptureKit/Sources/TranscriptedCaptureKit/CaptureLibraryPathSafety.swift
//     (TranscriptedCaptureKit)
//
// These are three independent build units that compile in total isolation
// with no shared module boundary between them (app target via raw `swiftc`,
// TranscriptedCore via SPM, TranscriptedCaptureKit via SPM), so this file
// cannot be a single physical file shared three ways. A git symlink was
// tried first and reverted: on a checkout with `core.symlinks=false`, git
// materializes a symlink as a plain text file containing the literal link
// target, which fails to compile under plain `swift test`, Xcode/SPM, and
// the CaptureKit package build. Real duplicated files are the portable
// option.
//
// The single, dependency-free (pure Foundation) definition of "is this
// filesystem path safe to use as a Transcripted capture-library / meeting
// save-path root?" lives here.
//
// EDIT ALL THREE FILES TOGETHER. `Tests/CaptureLibraryPathSafetySyncTests.swift`
// reads all three from disk and fails if any one of them diverges by even a
// byte — that test is the enforcement mechanism for this rule, replacing the
// three old hand-written "keep this rule in lockstep" comments this file's
// history removed.
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

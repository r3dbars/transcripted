import Foundation

/// Result of resolving a caller-supplied filename against a trusted base
/// directory.
public enum CapturePathResolutionStatus: Equatable {
    case valid(URL)
    case missing
    case invalid
}

/// Guards direct file reads against path traversal, symlink escapes, and
/// out-of-root paths. Shared by `TranscriptedCLI` and `TranscriptedMCP` so the
/// security-critical validation lives in exactly one place; both tools expose
/// it under their own local names (`CLIPathSecurity` / `PathSecurity`).
public enum CapturePathSecurity {
    /// Resolve `requestedName` inside `baseDirectory`, optionally appending a
    /// file extension when the name does not already carry it. Rejects any
    /// candidate that would escape `baseDirectory`.
    public static func resolveReadableFile(
        named requestedName: String,
        appendingExtension pathExtension: String? = nil,
        in baseDirectory: URL
    ) -> CapturePathResolutionStatus {
        let candidateName: String
        if let pathExtension, !requestedName.hasSuffix(".\(pathExtension)") {
            candidateName = requestedName + ".\(pathExtension)"
        } else {
            candidateName = requestedName
        }

        let candidateURL = baseDirectory
            .appendingPathComponent(candidateName)
            .standardizedFileURL
        let standardizedBase = baseDirectory.standardizedFileURL

        guard candidateURL.path.hasPrefix(standardizedBase.path + "/") else {
            return .invalid
        }
        guard FileManager.default.fileExists(atPath: candidateURL.path) else {
            return .missing
        }

        return validateExistingFile(candidateURL, under: baseDirectory)
    }

    /// Validate an already-built URL: it must exist, be a regular (non-symlink)
    /// file, and stay within `baseDirectory` after symlink resolution.
    public static func validateExistingFile(
        _ url: URL,
        under baseDirectory: URL
    ) -> CapturePathResolutionStatus {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }

        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return .invalid
        }

        let resolvedBase = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let resolvedBasePath = resolvedBase.path
        let resolvedPath = resolvedURL.path

        guard resolvedPath == resolvedBasePath || resolvedPath.hasPrefix(resolvedBasePath + "/") else {
            return .invalid
        }

        return .valid(resolvedURL)
    }
}

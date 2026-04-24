import Foundation

enum CLIPathResolutionStatus {
    case valid(URL)
    case missing
    case invalid
}

enum CLIPathSecurity {
    static func resolveReadableFile(named requestedName: String, in baseDirectory: URL) -> CLIPathResolutionStatus {
        let candidateURL = baseDirectory
            .appendingPathComponent(requestedName)
            .standardizedFileURL
        let standardizedBase = baseDirectory.standardizedFileURL

        guard candidateURL.path.hasPrefix(standardizedBase.path + "/") else {
            return .invalid
        }

        return validateExistingFile(candidateURL, under: baseDirectory)
    }

    static func validateExistingFile(_ url: URL, under baseDirectory: URL) -> CLIPathResolutionStatus {
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
        guard resolvedURL.path == resolvedBase.path || resolvedURL.path.hasPrefix(resolvedBase.path + "/") else {
            return .invalid
        }

        return .valid(resolvedURL)
    }
}

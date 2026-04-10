import Foundation

enum PathResolutionStatus {
    case valid(URL)
    case missing
    case invalid
}

enum PathSecurity {
    static func resolveReadableFile(
        named requestedName: String,
        appendingExtension pathExtension: String? = nil,
        in baseDirectory: URL
    ) -> PathResolutionStatus {
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

    static func validateExistingFile(_ url: URL, under baseDirectory: URL) -> PathResolutionStatus {
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

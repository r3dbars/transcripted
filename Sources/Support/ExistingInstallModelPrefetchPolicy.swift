import Foundation

struct ExistingInstallModelPrefetchContext: Equatable {
    let isExistingInstall: Bool
    let selectedModel: TranscriptionModelChoice
    let isModelLoaded: Bool
    let isModelWorkInFlight: Bool
    let eagerModelWarmupEnabled: Bool
}

enum ExistingInstallModelPrefetchPolicy {
    static let startupDelayNanoseconds: UInt64 = 12_000_000_000

    static func hasExistingInstallSignals(
        onboardingCompleted: Bool,
        hasCaptureLibraryContent: Bool,
        hasExplicitLaunchAtLoginChoice: Bool
    ) -> Bool {
        // Fresh installs can complete onboarding before first dictation, so
        // this flag is not strong enough by itself for background model work.
        _ = onboardingCompleted
        return hasCaptureLibraryContent || hasExplicitLaunchAtLoginChoice
    }

    static func shouldPrefetch(_ context: ExistingInstallModelPrefetchContext) -> Bool {
        guard context.isExistingInstall else { return false }
        guard context.selectedModel == .parakeetTDTv3 else { return false }
        guard !context.eagerModelWarmupEnabled else { return false }
        guard !context.isModelLoaded else { return false }
        guard !context.isModelWorkInFlight else { return false }
        return true
    }

    static func captureLibraryCandidateURLs(
        customPath: String?,
        appSupportRoot: URL
    ) -> [URL] {
        var candidates = [
            appSupportRoot
                .appendingPathComponent("captures", isDirectory: true)
                .standardizedFileURL
        ]

        let trimmedCustomPath = customPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCustomPath.isEmpty {
            let customURL = URL(fileURLWithPath: trimmedCustomPath, isDirectory: true)
            if TranscriptedStoragePreferences.isSafeCaptureLibraryURL(customURL) {
                let standardized = customURL.standardizedFileURL
                if !candidates.contains(standardized) {
                    candidates.append(standardized)
                }
            }
        }

        return candidates
    }

    static func captureLibraryHasContent(
        at captureLibraryURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        ["dictations", "meetings"].contains { subdirectory in
            let directory = captureLibraryURL.appendingPathComponent(subdirectory, isDirectory: true)
            return directoryContainsDirectRegularFile(directory, fileManager: fileManager)
        }
    }

    private static func directoryContainsDirectRegularFile(
        _ directory: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }

        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for fileURL in fileURLs {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                return true
            }
        }

        return false
    }
}

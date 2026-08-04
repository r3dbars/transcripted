import Foundation
import AVFoundation

/// Validates system conditions before starting a recording to prevent data loss
public enum RecordingValidator {

    /// Minimum free disk space required to start a recording.
    ///
    /// Meeting capture can write dual WAV streams fast enough that a 100MB
    /// floor lets recordings begin with only a few minutes of runway.
    public static let minimumDiskSpace: Int64 = 1024 * 1024 * 1024

    /// Result of validation check
    public enum ValidationResult {
        case success
        case failure(String)

        public var isValid: Bool {
            if case .success = self { return true }
            return false
        }

        public var errorMessage: String? {
            if case .failure(let message) = self { return message }
            return nil
        }
    }

    /// Performs all pre-recording validation checks.
    /// - Parameter paths: Filesystem layout to probe. Defaults to `CoreStoragePaths.default`.
    public static func validateRecordingConditions(paths: CoreStoragePaths = .default) -> ValidationResult {
        // Validate custom save path if set
        if let customPath = normalizedCustomSavePath(),
           !customPath.isEmpty {
            if let rawPathResult = validateRawSavePath(customPath) {
                return rawPathResult
            }

            let savePathResult = validateSavePath(URL(fileURLWithPath: customPath))
            if case .failure(_) = savePathResult {
                return savePathResult
            }
        }

        // Check disk space
        if let diskSpaceResult = checkDiskSpace(paths: paths), case .failure(_) = diskSpaceResult {
            return diskSpaceResult
        }

        // Check file permissions
        if let permissionsResult = checkFilePermissions(paths: paths), case .failure(_) = permissionsResult {
            return permissionsResult
        }

        // Check audio devices
        if let deviceResult = checkAudioDevices(), case .failure(_) = deviceResult {
            return deviceResult
        }

        return .success
    }

    /// Checks if sufficient disk space is available on the configured save volume
    private static func checkDiskSpace(paths: CoreStoragePaths) -> ValidationResult? {
        let checkPath = resolvedSaveDirectory(paths: paths)

        do {
            let probeURL = diskSpaceProbeURL(for: checkPath)
            let values = try probeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            guard let availableCapacity = values.volumeAvailableCapacity else {
                return .failure("Cannot determine available disk space. Check that your save location is accessible.")
            }

            if Int64(availableCapacity) < minimumDiskSpace {
                let availableMB = Int64(availableCapacity) / (1024 * 1024)
                let requiredMB = minimumDiskSpace / (1024 * 1024)
                return .failure("Not enough disk space (\(availableMB)MB free, need \(requiredMB)MB). Free up space and try again.")
            }

            return .success
        } catch {
            return .failure("Error checking disk space: \(error.localizedDescription)")
        }
    }

    /// Resolves a disk-space probe target even when the final save directory does not
    /// exist yet, which is common on first launch and for newly chosen custom paths.
    static func diskSpaceProbeURL(for candidateURL: URL, fileManager: FileManager = .default) -> URL {
        var probeURL = candidateURL

        while !fileManager.fileExists(atPath: probeURL.path) {
            let parentURL = probeURL.deletingLastPathComponent()
            guard parentURL.path != probeURL.path else { break }
            probeURL = parentURL
        }

        return probeURL
    }

    /// Checks if we have write permissions to the configured transcripts folder
    private static func checkFilePermissions(paths: CoreStoragePaths) -> ValidationResult? {
        let transcriptsDir = resolvedSaveDirectory(paths: paths)
        // Ensure the directory exists before probing — first run on a new install starts with nothing
        try? FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)

        let testFile = transcriptsDir.appendingPathComponent(".murmur_permission_test")

        do {
            // Try to write a test file
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            // Clean up test file
            try? FileManager.default.removeItem(at: testFile)
            return .success
        } catch {
            return .failure("Can't write to save folder. Check Finder permissions for \(transcriptsDir.path).")
        }
    }

    static func resolvedSaveDirectory(paths: CoreStoragePaths) -> URL {
        if let customPath = normalizedCustomSavePath(),
           !customPath.isEmpty {
            if validateRawSavePath(customPath) != nil {
                return paths.transcripts
            }

            let candidate = URL(fileURLWithPath: customPath, isDirectory: true)
                .appendingPathComponent("meetings", isDirectory: true)
            // Security: validate the path even in internal callers (checkDiskSpace,
            // checkFilePermissions) that bypass the UI-level validation in
            // validateRecordingConditions. Without this guard a UserDefaults value
            // containing ".." traversal components could cause the permission-test file
            // (.murmur_permission_test) to be written outside the intended directory.
            if case .failure = validateSavePath(candidate) {
                return paths.transcripts
            }
            return candidate
        }

        return paths.transcripts
    }

    // MARK: - Save Path Validation

    static func normalizedCustomSavePath(userDefaults: UserDefaults = .standard) -> String? {
        userDefaults.string(forKey: "transcriptSaveLocation")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validateRawSavePath(_ path: String) -> ValidationResult? {
        path.hasPrefix("/") ? nil : .failure("Save path must be an absolute filesystem path")
    }

    /// Validates a custom save path is safe to use.
    /// Resolves symlinks and rejects paths containing `..` traversals or targeting system directories.
    /// - Parameter url: The candidate save directory URL
    /// - Returns: `.success` if the path is safe, `.failure` with reason otherwise
    ///
    /// Delegates to the shared save-path safety predicate — see
    /// CaptureLibraryPathSafety.swift's header comment for why this rule lives
    /// in exactly one file, vendored into TranscriptedCore, the app target
    /// (TranscriptedStoragePaths), and TranscriptedCaptureKit (CaptureLibraryResolver).
    public static func validateSavePath(_ url: URL) -> ValidationResult {
        switch CaptureLibraryPathSafety.evaluate(url) {
        case .safe:
            return .success
        case .notAbsolutePath:
            return .failure("Save path must be an absolute filesystem path")
        case .containsParentTraversal:
            return .failure("Save path cannot contain '..' components")
        case .isRootPath:
            return .failure("Cannot save transcripts to system directory: /")
        case .forbiddenSystemPath(let prefix):
            return .failure("Cannot save transcripts to system directory: \(prefix)")
        }
    }

    /// Checks if audio devices are accessible
    private static func checkAudioDevices() -> ValidationResult? {
        // Check microphone device
        guard AVCaptureDevice.default(for: .audio) != nil else {
            return .failure("No microphone found. Connect a microphone or headset and try again.")
        }

        // Check if microphone is authorized
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneStatus == .denied {
            return .failure("Microphone access denied. Go to System Settings \u{2192} Privacy & Security \u{2192} Microphone and enable Transcripted.")
        }

        // If not authorized (notDetermined or restricted), allow recording to proceed
        // but warn that recording will fail until permission is granted
        if microphoneStatus != .authorized {
            return .success
        }

        return .success
    }
}

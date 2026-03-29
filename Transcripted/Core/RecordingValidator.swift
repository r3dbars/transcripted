import Foundation
import AVFoundation

/// Validates system conditions before starting a recording to prevent data loss
class RecordingValidator {

    /// Minimum required disk space in bytes (100MB)
    static let minimumDiskSpace: Int64 = 100 * 1024 * 1024

    /// Result of validation check
    enum ValidationResult {
        case success
        case failure(String)

        var isValid: Bool {
            if case .success = self { return true }
            return false
        }

        var errorMessage: String? {
            if case .failure(let message) = self { return message }
            return nil
        }
    }

    /// Performs all pre-recording validation checks
    static func validateRecordingConditions() -> ValidationResult {
        // Validate custom save path if set
        if let customPath = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !customPath.isEmpty {
            let savePathResult = validateSavePath(URL(fileURLWithPath: customPath))
            if case .failure(_) = savePathResult {
                return savePathResult
            }
        }

        // Check disk space
        if let diskSpaceResult = checkDiskSpace(), case .failure(_) = diskSpaceResult {
            return diskSpaceResult
        }

        // Check file permissions
        if let permissionsResult = checkFilePermissions(), case .failure(_) = permissionsResult {
            return permissionsResult
        }

        // Check audio devices
        if let deviceResult = checkAudioDevices(), case .failure(_) = deviceResult {
            return deviceResult
        }

        return .success
    }

    /// Checks if sufficient disk space is available on the configured save volume
    private static func checkDiskSpace() -> ValidationResult? {
        // Check the actual save location, not just Documents — user may save to an external drive
        let checkPath: URL
        if let customPath = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !customPath.isEmpty {
            checkPath = URL(fileURLWithPath: customPath)
        } else if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            checkPath = documentsPath
        } else {
            return .failure("Cannot access save folder")
        }

        do {
            let values = try checkPath.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            guard let availableCapacity = values.volumeAvailableCapacity else {
                return .failure("Cannot determine available disk space")
            }

            if Int64(availableCapacity) < minimumDiskSpace {
                let availableMB = Int64(availableCapacity) / (1024 * 1024)
                return .failure("Insufficient disk space: Only \(availableMB)MB available. Please free up space and try again.")
            }

            return .success
        } catch {
            return .failure("Error checking disk space: \(error.localizedDescription)")
        }
    }

    /// Checks if we have write permissions to the Documents folder
    private static func checkFilePermissions() -> ValidationResult? {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return .failure("Cannot access Documents folder")
        }

        let testFile = documentsPath.appendingPathComponent(".murmur_permission_test")

        do {
            // Try to write a test file
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            // Clean up test file
            try? FileManager.default.removeItem(at: testFile)
            return .success
        } catch {
            return .failure("No write permission to Documents folder. Please check app permissions.")
        }
    }

    // MARK: - Save Path Validation

    /// System directories that must never be used as a transcript save location.
    private static let forbiddenPrefixes = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private"]

    /// Validates a custom save path is safe to use.
    /// Resolves symlinks and rejects paths containing `..` traversals or targeting system directories.
    /// - Parameter url: The candidate save directory URL
    /// - Returns: `.success` if the path is safe, `.failure` with reason otherwise
    static func validateSavePath(_ url: URL) -> ValidationResult {
        // Security: check for ".." traversal components on the RAW path before symlink resolution.
        // After resolvingSymlinksInPath(), ".." components are already normalised away and would
        // never appear in pathComponents — making a post-resolution check useless dead code.
        // Checking the raw components first ensures the check is actually exercised.
        let rawComponents = url.pathComponents
        if rawComponents.contains("..") {
            return .failure("Save path cannot contain '..' components")
        }

        // Resolve symlinks so that a symlink pointing at e.g. /System cannot bypass
        // the forbidden-prefix check below.
        let resolved = url.resolvingSymlinksInPath()
        let resolvedPath = resolved.path

        // Reject system directories
        for prefix in forbiddenPrefixes {
            if resolvedPath.hasPrefix(prefix) {
                return .failure("Cannot save transcripts to system directory: \(prefix)")
            }
        }

        return .success
    }

    /// Checks if audio devices are accessible
    private static func checkAudioDevices() -> ValidationResult? {
        // Check microphone device
        guard let defaultInputDevice = AVCaptureDevice.default(for: .audio) else {
            return .failure("No microphone device found. Please connect a microphone and try again.")
        }

        // Check if microphone is authorized
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneStatus == .denied {
            return .failure("Microphone access denied. Please grant microphone permissions in System Settings.")
        }

        // If not authorized (notDetermined or restricted), allow recording to proceed
        // but warn that recording will fail until permission is granted
        if microphoneStatus != .authorized {
            return .success
        }

        return .success
    }
}

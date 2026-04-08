import Foundation

struct HealthChecker {
    let dataPath: URL

    init(dataPath: URL? = nil) {
        self.dataPath = dataPath ?? transcriptedMeetingDirectory()
    }

    func validate() -> [ValidationResult] {
        var results: [ValidationResult] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Transcript directory
        let transcriptDir = dataPath
        if fm.isWritableFile(atPath: transcriptDir.path) {
            results.append(.pass("health/transcript-dir", target: transcriptDir.path))
        } else if fm.fileExists(atPath: transcriptDir.path) {
            results.append(.fail("health/transcript-dir", target: transcriptDir.path, detail: "Directory exists but is not writable"))
        } else {
            results.append(.fail("health/transcript-dir", target: transcriptDir.path, detail: "Directory does not exist"))
        }

        // Logs directory
        let logsDir = dataPath.deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true)
        if fm.fileExists(atPath: logsDir.path) {
            results.append(.pass("health/logs-dir", target: logsDir.path))
        } else {
            results.append(.warn("health/logs-dir", target: logsDir.path, detail: "Logs directory does not exist"))
        }

        // Disk space (>= 5GB)
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage {
            let gb = Double(available) / 1_073_741_824
            if gb >= 5.0 {
                results.append(.pass("health/disk-space", target: String(format: "%.1f GB free", gb)))
            } else {
                results.append(.warn("health/disk-space", target: String(format: "%.1f GB free", gb), detail: "Low disk space (< 5GB)"))
            }
        }

        // macOS version
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionStr = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        if version.majorVersion > 14 || (version.majorVersion == 14 && version.minorVersion >= 2) {
            results.append(.pass("health/macos-version", target: "macOS \(versionStr)"))
        } else {
            results.append(.fail("health/macos-version", target: "macOS \(versionStr)", detail: "Requires macOS 14.2+"))
        }

        // Recent crash reports
        let crashDir = home.appendingPathComponent("Library/Logs/DiagnosticReports")
        if let files = try? fm.contentsOfDirectory(atPath: crashDir.path) {
            let recent = files.filter { $0.contains("Transcripted") }
            if recent.isEmpty {
                results.append(.pass("health/no-crashes", target: "No Transcripted crash reports"))
            } else {
                results.append(.warn("health/no-crashes", target: "\(recent.count) crash reports", detail: recent.prefix(3).joined(separator: ", ")))
            }
        } else {
            results.append(.pass("health/no-crashes", target: "DiagnosticReports not accessible"))
        }

        return results
    }
}

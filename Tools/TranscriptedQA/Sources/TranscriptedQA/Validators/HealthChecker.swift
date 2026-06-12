import Foundation

struct HealthChecker {
    let paths: QADataDirectories

    init(paths: QADataDirectories = .resolve()) {
        self.paths = paths
    }

    func validate() -> [ValidationResult] {
        var results: [ValidationResult] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Meetings capture directory
        if fm.isWritableFile(atPath: paths.meetingsDir.path) {
            results.append(.pass("health/meetings-dir", target: paths.meetingsDir.path))
        } else if fm.fileExists(atPath: paths.meetingsDir.path) {
            results.append(.fail("health/meetings-dir", target: paths.meetingsDir.path, detail: "Directory exists but is not writable"))
        } else {
            results.append(.fail("health/meetings-dir", target: paths.meetingsDir.path, detail: "Directory does not exist"))
        }

        // State directory
        if fm.isWritableFile(atPath: paths.stateDir.path) {
            results.append(.pass("health/state-dir", target: paths.stateDir.path))
        } else if fm.fileExists(atPath: paths.stateDir.path) {
            results.append(.fail("health/state-dir", target: paths.stateDir.path, detail: "Directory exists but is not writable"))
        } else {
            results.append(.warn("health/state-dir", target: paths.stateDir.path, detail: "Directory does not exist"))
        }

        // Logs directory
        let logsDir = paths.logsDirectory
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
        // The app itself targets arm64-apple-macos26.0; a lower version passing
        // here would green-light a machine that cannot run Transcripted.
        if version.majorVersion >= 26 {
            results.append(.pass("health/macos-version", target: "macOS \(versionStr)"))
        } else {
            results.append(.fail("health/macos-version", target: "macOS \(versionStr)", detail: "Requires macOS 26+"))
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

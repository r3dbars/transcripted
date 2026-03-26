import Foundation

struct HealthChecker {

    func validate() -> [ValidationResult] {
        var results: [ValidationResult] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Transcript directory
        let transcriptDir = home.appendingPathComponent("Documents/Transcripted")
        if fm.isWritableFile(atPath: transcriptDir.path) {
            results.append(.pass("health/transcript-dir", target: transcriptDir.path))
        } else if fm.fileExists(atPath: transcriptDir.path) {
            results.append(.fail("health/transcript-dir", target: transcriptDir.path, detail: "Directory exists but is not writable"))
        } else {
            results.append(.fail("health/transcript-dir", target: transcriptDir.path, detail: "Directory does not exist"))
        }

        // Logs directory
        let logsDir = home.appendingPathComponent("Library/Logs/Transcripted")
        if fm.fileExists(atPath: logsDir.path) {
            results.append(.pass("health/logs-dir", target: logsDir.path))
        } else {
            results.append(.warn("health/logs-dir", target: logsDir.path, detail: "Logs directory does not exist"))
        }

        // Qwen model cache
        let qwenCache = home.appendingPathComponent("Library/Caches/models/mlx-community/Qwen3.5-4B-4bit")
        if fm.fileExists(atPath: qwenCache.path) {
            let files = (try? fm.contentsOfDirectory(atPath: qwenCache.path)) ?? []
            if files.count > 5 {
                results.append(.pass("health/qwen-model", target: "Qwen3.5-4B-4bit (\(files.count) files)"))
            } else {
                results.append(.warn("health/qwen-model", target: qwenCache.path, detail: "Only \(files.count) files — model may be incomplete"))
            }
        } else {
            results.append(.warn("health/qwen-model", target: qwenCache.path, detail: "Model not cached"))
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

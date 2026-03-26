import Foundation

struct LogValidator {
    let logPath: String

    func validate() -> [ValidationResult] {
        var results: [ValidationResult] = []
        let target = "app.jsonl"

        guard FileManager.default.fileExists(atPath: logPath) else {
            return [.warn("logs/file-exists", target: target, detail: "app.jsonl not found")]
        }

        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return [.fail("logs/readable", target: target, detail: "Cannot read app.jsonl")]
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        if lines.isEmpty {
            return [.warn("logs/not-empty", target: target, detail: "Log file is empty")]
        }

        // Parse all lines
        let validSubsystems = Set(["audio", "audio.mic", "audio.system", "transcription",
                                    "pipeline", "speaker-db", "services", "ui", "stats", "app"])
        let validLevels = Set(["debug", "info", "warning", "error"])

        var validCount = 0
        var invalidLines: [Int] = []
        var errorCount = 0
        var warningCount = 0
        var subsystemOk = true
        var levelOk = true
        var keysOk = true

        for (i, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                invalidLines.append(i + 1)
                continue
            }
            validCount += 1

            // Required keys
            if json["t"] == nil || json["l"] == nil || json["s"] == nil || json["m"] == nil {
                keysOk = false
            }

            // Level check
            if let level = json["l"] as? String {
                if !validLevels.contains(level) { levelOk = false }
                if level == "error" { errorCount += 1 }
                if level == "warning" { warningCount += 1 }
            }

            // Subsystem check
            if let subsystem = json["s"] as? String {
                if !validSubsystems.contains(subsystem) { subsystemOk = false }
            }
        }

        // JSON valid
        if invalidLines.isEmpty {
            results.append(.pass("logs/jsonl-valid", target: "\(target) (\(lines.count) entries)"))
        } else {
            results.append(.fail("logs/jsonl-valid", target: target, detail: "\(invalidLines.count) invalid lines (first: line \(invalidLines.first ?? 0))"))
        }

        // Required keys
        if keysOk {
            results.append(.pass("logs/jsonl-required-keys", target: target))
        } else {
            results.append(.fail("logs/jsonl-required-keys", target: target, detail: "Some entries missing t/l/s/m keys"))
        }

        // Valid levels
        if levelOk {
            results.append(.pass("logs/jsonl-valid-levels", target: target))
        } else {
            results.append(.fail("logs/jsonl-valid-levels", target: target, detail: "Unknown log levels found"))
        }

        // Valid subsystems
        if subsystemOk {
            results.append(.pass("logs/jsonl-valid-subsystems", target: target))
        } else {
            results.append(.warn("logs/jsonl-valid-subsystems", target: target, detail: "Unknown subsystems found"))
        }

        // Entry count <= 2000
        if lines.count <= 2000 {
            results.append(.pass("logs/jsonl-entry-count", target: target))
        } else {
            results.append(.warn("logs/jsonl-entry-count", target: target, detail: "\(lines.count) entries (rolling limit is 2000)"))
        }

        // Error rate
        let total = max(lines.count, 1)
        let errorRate = Double(errorCount + warningCount) / Double(total)
        if errorRate < 0.10 {
            results.append(.pass("logs/jsonl-error-rate", target: "\(target) (\(errorCount) errors, \(warningCount) warnings)"))
        } else {
            results.append(.warn("logs/jsonl-error-rate", target: target, detail: "\(Int(errorRate * 100))% error/warning rate (\(errorCount) errors, \(warningCount) warnings)"))
        }

        return results
    }
}

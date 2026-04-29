import Foundation

enum ValidationStatus: String, Codable {
    case pass = "PASS"
    case fail = "FAIL"
    case warn = "WARN"
}

struct ValidationResult: Codable {
    let check: String
    let status: ValidationStatus
    let target: String
    let detail: String?

    init(check: String, status: ValidationStatus, target: String, detail: String? = nil) {
        self.check = check
        self.status = status
        self.target = target
        self.detail = detail
    }

    static func pass(_ check: String, target: String) -> ValidationResult {
        ValidationResult(check: check, status: .pass, target: target)
    }

    static func fail(_ check: String, target: String, detail: String) -> ValidationResult {
        ValidationResult(check: check, status: .fail, target: target, detail: detail)
    }

    static func warn(_ check: String, target: String, detail: String) -> ValidationResult {
        ValidationResult(check: check, status: .warn, target: target, detail: detail)
    }

    var textLine: String {
        let statusStr = status.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0)
        let checkStr = check.padding(toLength: 36, withPad: " ", startingAt: 0)
        if let detail = detail {
            return "\(statusStr)  \(checkStr)  \(target)  \(detail)"
        }
        return "\(statusStr)  \(checkStr)  \(target)"
    }
}

struct ValidationReport: Codable {
    let results: [ValidationResult]
    let summary: Summary
    let automation: AutomationSummary
    let failureFingerprints: [FailureFingerprint]

    struct Summary: Codable {
        let passed: Int
        let failed: Int
        let warnings: Int
    }

    struct AutomationSummary: Codable {
        let status: ValidationStatus
        let exitCode: Int
        let generatedAt: String
        let resultCount: Int
        let failureFingerprintCount: Int
    }

    struct FailureFingerprint: Codable {
        let id: String
        let status: ValidationStatus
        let check: String
        let detail: String?
        let count: Int
        let targets: [String]
    }

    init(results: [ValidationResult], generatedAt: Date = Date()) {
        self.results = results
        self.summary = Summary(
            passed: results.filter { $0.status == .pass }.count,
            failed: results.filter { $0.status == .fail }.count,
            warnings: results.filter { $0.status == .warn }.count
        )
        self.failureFingerprints = FailureFingerprint.build(from: results)
        let exitCode = summary.failed > 0 ? 1 : 0
        self.automation = AutomationSummary(
            status: ValidationReport.overallStatus(for: summary),
            exitCode: exitCode,
            generatedAt: ISO8601DateFormatter().string(from: generatedAt),
            resultCount: results.count,
            failureFingerprintCount: failureFingerprints.count
        )
    }

    var exitCode: Int32 {
        summary.failed > 0 ? 1 : 0
    }

    func printText() {
        for result in results {
            print(result.textLine)
        }
        print("\nSummary: \(summary.passed) passed, \(summary.failed) failed, \(summary.warnings) warnings")
    }

    func printJSON() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(self)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            } else {
                FileHandle.standardError.write(Data("Error: Failed to encode JSON report as UTF-8\n".utf8))
                Foundation.exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data("Error: Failed to encode JSON report: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func overallStatus(for summary: Summary) -> ValidationStatus {
        if summary.failed > 0 {
            return .fail
        }
        if summary.warnings > 0 {
            return .warn
        }
        return .pass
    }
}

private extension ValidationReport.FailureFingerprint {
    static func build(from results: [ValidationResult]) -> [Self] {
        let grouped = Dictionary(grouping: results.filter { $0.status != .pass }) { result in
            FingerprintKey(status: result.status, check: result.check, detail: result.detail)
        }

        return grouped.map { key, group in
            let targets = Array(Set(group.map(\.target))).sorted()
            return ValidationReport.FailureFingerprint(
                id: "fp-\(stableFingerprint(for: key.material))",
                status: key.status,
                check: key.check,
                detail: key.detail,
                count: group.count,
                targets: targets
            )
        }
        .sorted {
            if statusRank($0.status) != statusRank($1.status) {
                return statusRank($0.status) < statusRank($1.status)
            }
            if $0.check != $1.check {
                return $0.check < $1.check
            }
            return ($0.detail ?? "") < ($1.detail ?? "")
        }
    }

    private struct FingerprintKey: Hashable {
        let status: ValidationStatus
        let check: String
        let detail: String?

        var material: String {
            [status.rawValue, check, detail ?? ""].joined(separator: "|")
        }
    }

    private static func statusRank(_ status: ValidationStatus) -> Int {
        switch status {
        case .fail: return 0
        case .warn: return 1
        case .pass: return 2
        }
    }

    private static func stableFingerprint(for value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        let prime: UInt64 = 1099511628211
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(format: "%016llx", hash)
    }
}

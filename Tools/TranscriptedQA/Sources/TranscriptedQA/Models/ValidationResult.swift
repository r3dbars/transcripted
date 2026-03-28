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

    struct Summary: Codable {
        let passed: Int
        let failed: Int
        let warnings: Int
    }

    init(results: [ValidationResult]) {
        self.results = results
        self.summary = Summary(
            passed: results.filter { $0.status == .pass }.count,
            failed: results.filter { $0.status == .fail }.count,
            warnings: results.filter { $0.status == .warn }.count
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
        if let data = try? encoder.encode(self), let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}

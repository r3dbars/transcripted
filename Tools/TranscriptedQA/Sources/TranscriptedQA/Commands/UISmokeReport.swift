import Foundation

enum UIAutomationSmokeStatus: String, Codable {
    case pass = "PASS"
    case fail = "FAIL"
    case incomplete = "INCOMPLETE"
}

struct UIAutomationSmokeCheck: Codable, Equatable {
    let id: String
    let title: String
    let status: UIAutomationSmokeStatus
    let target: String
    let detail: String?
    let observed: [AXObservedElement]

    static func pass(_ id: String, _ title: String, target: String, observed: [AXObservedElement] = []) -> UIAutomationSmokeCheck {
        UIAutomationSmokeCheck(id: id, title: title, status: .pass, target: target, detail: nil, observed: observed)
    }

    static func fail(_ id: String, _ title: String, target: String, detail: String, observed: [AXObservedElement] = []) -> UIAutomationSmokeCheck {
        UIAutomationSmokeCheck(id: id, title: title, status: .fail, target: target, detail: detail, observed: observed)
    }

    static func incomplete(_ id: String, _ title: String, target: String, detail: String, observed: [AXObservedElement] = []) -> UIAutomationSmokeCheck {
        UIAutomationSmokeCheck(id: id, title: title, status: .incomplete, target: target, detail: detail, observed: observed)
    }
}

struct UIAutomationSmokeReport: Codable, Equatable, ReportWritable {
    let runID: String
    let status: UIAutomationSmokeStatus
    let exitCode: Int32
    let generatedAt: String
    let appBundlePath: String
    let isolatedHomePath: String?
    let onboardingIsolatedHomePath: String?
    let appLogPath: String?
    let onboardingAppLogPath: String?
    let reportPath: String?
    let checks: [UIAutomationSmokeCheck]

    func printText() {
        let passed = checks.filter { $0.status == .pass }.count
        let flagged = checks.count - passed
        switch status {
        case .pass:
            print("PASS: tested \(passed)/\(checks.count) UI checks. Onboarding, menu bar, Home, Settings, and navigation are scriptable.")
        case .fail:
            print("FAIL: tested \(passed)/\(checks.count) UI checks. \(flagged) flagged.")
        case .incomplete:
            print("INCOMPLETE: tested \(passed)/\(checks.count) UI checks. \(flagged) flagged.")
        }

        for check in checks where check.status != .pass {
            print("\(check.status.rawValue): \(check.title) - \(check.detail ?? check.target)")
        }
        if let reportPath {
            print("Report: \(reportPath)")
        }
        if let appLogPath {
            print("App log: \(appLogPath)")
        }
        if let onboardingAppLogPath {
            print("Onboarding app log: \(onboardingAppLogPath)")
        }
    }
}

struct UIAutomationSmokeReportBuilder {
    let runID: String
    let appBundlePath: String
    let reportPath: String?
    var isolatedHomePath: String?
    var onboardingIsolatedHomePath: String?
    var appLogPath: String?
    var onboardingAppLogPath: String?
    private var checks: [UIAutomationSmokeCheck] = []

    init(runID: String, appBundlePath: String, reportPath: String?) {
        self.runID = runID
        self.appBundlePath = appBundlePath
        self.reportPath = reportPath
    }

    mutating func add(_ check: UIAutomationSmokeCheck) {
        checks.append(check)
    }

    func build(generatedAt: Date = Date()) -> UIAutomationSmokeReport {
        let status: UIAutomationSmokeStatus
        if checks.contains(where: { $0.status == .fail }) {
            status = .fail
        } else if checks.contains(where: { $0.status == .incomplete }) {
            status = .incomplete
        } else {
            status = .pass
        }

        let exitCode: Int32
        switch status {
        case .pass:
            exitCode = 0
        case .fail:
            exitCode = 1
        case .incomplete:
            exitCode = 3
        }

        return UIAutomationSmokeReport(
            runID: runID,
            status: status,
            exitCode: exitCode,
            generatedAt: ISO8601DateFormatter().string(from: generatedAt),
            appBundlePath: appBundlePath,
            isolatedHomePath: isolatedHomePath,
            onboardingIsolatedHomePath: onboardingIsolatedHomePath,
            appLogPath: appLogPath,
            onboardingAppLogPath: onboardingAppLogPath,
            reportPath: reportPath,
            checks: checks
        )
    }
}

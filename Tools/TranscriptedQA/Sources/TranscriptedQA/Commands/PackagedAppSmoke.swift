import ArgumentParser
import Darwin
import Foundation

struct PackagedAppSmoke: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "packaged-app-smoke",
        abstract: "Validate a built or packaged Transcripted.app before publishing a release."
    )

    @Option(name: .long, help: "Path to the built Transcripted.app bundle.")
    var app: String = "build/Transcripted.app"

    @Option(name: .long, help: "Path to the source Info.plist expected to match the built app.")
    var sourceInfoPlist: String = "Info.plist"

    @Option(name: .long, help: "Path to the release dSYM bundle.")
    var dsym: String = "build/Transcripted.app.dSYM"

    @Option(name: .long, help: "Path to the built DMG. Defaults to build/Transcripted-<CFBundleShortVersionString>.dmg.")
    var dmg: String?

    @Option(name: .long, help: "Path to the committed Sparkle appcast.")
    var appcast: String = "docs/appcast.xml"

    @Option(name: .long, parsing: .upToNextOption, help: "Local log files to scan for obvious privacy leaks.")
    var logPath: [String] = []

    @Option(name: .long, help: "Write a local JSON evidence report to this path.")
    var report: String?

    @Option(name: .long, help: "Write UI smoke JSON evidence to this path when --run-ui-smoke is set.")
    var uiReport: String?

    @Option(name: .long, help: "Write first-run reliability JSON evidence to this path when --run-first-run-reliability is set.")
    var firstRunReport: String?

    @Option(name: .long, help: "Seconds to wait for each UI smoke surface.")
    var uiTimeout: Double = 12

    @Option(name: .long, help: "Seconds to wait for each first-run reliability launch.")
    var firstRunTimeout: Double = 20

    @Flag(name: .long, help: "Warn instead of fail when the dSYM is missing or unverifiable.")
    var allowMissingDSYM = false

    @Flag(name: .long, help: "Warn instead of fail when the DMG is missing or unreadable.")
    var allowMissingDMG = false

    @Flag(name: .long, help: "Launch the built app and validate the menu bar through Accessibility.")
    var runUISmoke = false

    @Flag(name: .long, help: "Launch the packaged app inside isolated homes and containers to validate first-run reliability scenarios.")
    var runFirstRunReliability = false

    @Flag(name: .long, help: "Allow a pre-existing Transcripted process during --run-ui-smoke.")
    var allowExistingInstance = false

    @Flag(name: .long, help: "Ask macOS to show the Accessibility prompt during --run-ui-smoke if needed.")
    var promptForAccessibility = false

    @Flag(name: .long, help: "Skip codesign verification. This downgrades signing proof to INCOMPLETE.")
    var skipCodeSignatureCheck = false

    func run() throws {
        let runner = PackagedAppSmokeRunner(
            appBundlePath: app,
            sourceInfoPlistPath: sourceInfoPlist,
            dSYMPath: dsym,
            dmgPath: dmg,
            appcastPath: appcast,
            logPaths: logPath,
            reportPath: report,
            uiReportPath: uiReport,
            firstRunReportPath: firstRunReport,
            uiTimeout: uiTimeout,
            firstRunTimeout: firstRunTimeout,
            requireDSYM: !allowMissingDSYM,
            requireDMG: !allowMissingDMG,
            runUISmoke: runUISmoke,
            runFirstRunReliability: runFirstRunReliability,
            allowExistingInstance: allowExistingInstance,
            promptForAccessibility: promptForAccessibility,
            verifyCodeSignature: !skipCodeSignatureCheck
        )
        let smokeReport = runner.run()
        smokeReport.printText()
        try smokeReport.writeIfRequested()

        if smokeReport.exitCode != 0 {
            throw ExitCode(smokeReport.exitCode)
        }
    }
}

struct PackagedAppSmokeCheck: Codable, Equatable {
    let id: String
    let status: ValidationStatus
    let target: String
    let detail: String

    static func pass(_ id: String, target: String, detail: String) -> PackagedAppSmokeCheck {
        PackagedAppSmokeCheck(id: id, status: .pass, target: target, detail: detail)
    }

    static func warn(_ id: String, target: String, detail: String) -> PackagedAppSmokeCheck {
        PackagedAppSmokeCheck(id: id, status: .warn, target: target, detail: detail)
    }

    static func fail(_ id: String, target: String, detail: String) -> PackagedAppSmokeCheck {
        PackagedAppSmokeCheck(id: id, status: .fail, target: target, detail: detail)
    }
}

struct PackagedAppSmokeReport: Codable, Equatable, ReportWritable {
    struct Summary: Codable, Equatable {
        let passed: Int
        let failed: Int
        let warnings: Int
    }

    let runID: String
    let generatedAt: String
    let appBundlePath: String
    let sourceInfoPlistPath: String
    let dSYMPath: String
    let dmgPath: String?
    let appcastPath: String
    let logPaths: [String]
    let uiReportPath: String?
    let firstRunReportPath: String?
    let reportPath: String?
    let checks: [PackagedAppSmokeCheck]

    var summary: Summary {
        Summary(
            passed: checks.filter { $0.status == .pass }.count,
            failed: checks.filter { $0.status == .fail }.count,
            warnings: checks.filter { $0.status == .warn }.count
        )
    }

    var status: ValidationStatus {
        if summary.failed > 0 { return .fail }
        if summary.warnings > 0 { return .warn }
        return .pass
    }

    var exitCode: Int32 {
        switch status {
        case .pass: return 0
        case .fail: return 1
        case .warn: return 3
        }
    }

    func printText() {
        let passed = summary.passed
        let total = checks.count
        switch status {
        case .pass:
            print("PASS: tested \(passed)/\(total) packaged-app checks. App bundle, Sparkle config, signing, artifacts, and logs look coherent.")
        case .fail:
            print("FAIL: tested \(passed)/\(total) packaged-app checks. \(summary.failed + summary.warnings) flagged.")
        case .warn:
            print("INCOMPLETE: tested \(passed)/\(total) packaged-app checks. \(summary.warnings) warning(s).")
        }

        for check in checks where check.status != .pass {
            print("\(check.status.rawValue): \(check.id) - \(check.detail)")
        }
        if let uiReportPath {
            print("UI report: \(uiReportPath)")
        }
        if let firstRunReportPath {
            print("First-run report: \(firstRunReportPath)")
        }
        if let reportPath {
            print("Report: \(reportPath)")
        }
    }
}

protocol PackagedAppSmokeCommandRunning {
    func run(_ executable: String, _ arguments: [String]) -> PackagedAppSmokeCommandResult
}

struct PackagedAppSmokeCommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct ProcessPackagedAppSmokeCommandRunner: PackagedAppSmokeCommandRunning {
    func run(_ executable: String, _ arguments: [String]) -> PackagedAppSmokeCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        // Drain one combined pipe while the child is running. Waiting first can
        // deadlock when tools such as `hdiutil imageinfo` fill the pipe buffer.
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            return PackagedAppSmokeCommandResult(exitCode: process.terminationStatus, stdout: output, stderr: "")
        } catch {
            return PackagedAppSmokeCommandResult(exitCode: 127, stdout: "", stderr: error.localizedDescription)
        }
    }
}

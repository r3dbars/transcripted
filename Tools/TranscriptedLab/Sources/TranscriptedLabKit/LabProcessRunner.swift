import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class LabProcessRunner: @unchecked Sendable {
    public init() {}

    public func run(_ command: LabCommand, timeoutSeconds: Double) async throws -> LabProcessResult {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("transcripted-lab-process-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let stdoutURL = tempRoot.appendingPathComponent("stdout.log")
        let stderrURL = tempRoot.appendingPathComponent("stderr.log")
        _ = fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        _ = fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: command.workingDirectory, isDirectory: true)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        var environment = ProcessInfo.processInfo.environment
        command.environment.forEach { environment[$0.key] = $0.value }
        process.environment = environment

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            throw LabRunnerError.processLaunch(error.localizedDescription)
        }

        let timeout = max(1, timeoutSeconds)
        var timedOut = false
        while process.isRunning {
            if Date().timeIntervalSince(startedAt) >= timeout {
                timedOut = true
                process.terminate()
                let graceDeadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < graceDeadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                }
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        process.waitUntilExit()

        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()
        let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        let duration = Date().timeIntervalSince(startedAt)

        return LabProcessResult(
            exitCode: process.terminationStatus,
            timedOut: timedOut,
            durationSeconds: duration,
            stdoutTail: LabText.tail(LabText.sanitized(stdout)),
            stderrTail: LabText.tail(LabText.sanitized(stderr))
        )
    }
}

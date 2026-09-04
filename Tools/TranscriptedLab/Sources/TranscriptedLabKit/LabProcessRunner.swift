import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class LabProcessRunner: @unchecked Sendable {
    public init() {}

    public func run(_ command: LabCommand, timeoutSeconds: Double) async throws -> LabProcessResult {
        try Task.checkCancellation()
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw LabRunnerError.invalidConfiguration("Timeout must be a finite positive number.")
        }
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

        // Foundation launches Process in a separate process group on supported
        // hosts. Verify that ownership before ever signaling a negative PID.
        // The leader may already have exited by the time run() returns.
        let groupID = process.processIdentifier
        let observedGroup = getpgid(groupID)
        guard groupID > 0, groupID != getpgrp(),
              observedGroup == groupID || (observedGroup == -1 && errno == ESRCH) else {
            // Ownership failed: signal only our direct child, never its group.
            await stopOwnedProcesses(signalTarget: process.processIdentifier)
            process.waitUntilExit()
            throw LabRunnerError.processLaunch("Experiment did not receive an isolated process group.")
        }

        let deadline = ProcessInfo.processInfo.systemUptime + max(1, timeoutSeconds)
        var timedOut = false
        while process.isRunning && !Task.isCancelled {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true
                break
            }
            await pause()
        }
        if timedOut || Task.isCancelled || kill(-groupID, 0) == 0 {
            await stopOwnedProcesses(signalTarget: -groupID)
        }
        process.waitUntilExit()
        try Task.checkCancellation()

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

    private func stopOwnedProcesses(signalTarget: pid_t) async {
        _ = kill(signalTarget, SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while kill(signalTarget, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline {
            await pause()
        }
        // The shell can exit before a child that ignores TERM. Escalate against
        // the same owned group even after the Process leader has exited.
        if kill(signalTarget, 0) == 0 { _ = kill(signalTarget, SIGKILL) }
    }

    private func pause() async {
        // Cleanup must still yield after cancellation; try? Task.sleep would
        // return immediately and spin while waiting for children to exit.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                continuation.resume()
            }
        }
    }
}

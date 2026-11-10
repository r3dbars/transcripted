import Foundation

/// Bounded subprocess admission and interpretation, separate from the native
/// Process adapter so deadline decisions can be exercised without a process.
enum LlamaShellProbe {
    struct Completion: Equatable, Sendable {
        let status: Int32
        let exitedNormally: Bool
        let stdout: Data
        let stderr: Data
    }

    enum Outcome: Equatable, Sendable {
        case failed
        case timedOut
        case completed(Completion)
    }

    struct Driver {
        let start: () -> Bool
        let waitForExit: (TimeInterval) -> Bool
        let isRunning: () -> Bool
        let terminate: () -> Void
        let forceKill: () -> Void
        let completion: () -> Completion?
    }

    static func execute(driver: Driver, timeout: TimeInterval = 1) -> Outcome {
        guard driver.start() else { return .failed }
        if driver.waitForExit(timeout) {
            return driver.completion().map(Outcome.completed) ?? .failed
        }

        // Cleanup cannot turn an expired probe into usable partial evidence.
        // In particular, do not read its output after either cleanup wait.
        if driver.isRunning() { driver.terminate() }
        if !driver.waitForExit(0.2) {
            if driver.isRunning() { driver.forceKill() }
            _ = driver.waitForExit(0.2)
        }
        return .timedOut
    }

    static func listenerPIDs(from outcome: Outcome) -> [Int32]? {
        guard case let .completed(result) = outcome,
              result.exitedNormally, result.stderr.isEmpty else { return nil }
        // lsof uses 1 for an empty match as well as errors. Empty diagnostics
        // are the practical no-match convention, not proof of full visibility:
        // the existing -t flag also suppresses warnings.
        if result.status == 1 {
            return result.stdout.isEmpty ? [] : nil
        }
        guard result.status == 0,
              let output = String(data: result.stdout, encoding: .utf8) else { return nil }
        var pids: [Int32] = []
        for line in output.split(whereSeparator: \Character.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let pid = positivePID(text) else { return nil }
            pids.append(pid)
        }
        return pids
    }

    static func parentPID(from outcome: Outcome) -> String? {
        guard case let .completed(result) = outcome,
              result.exitedNormally, result.status == 0, result.stderr.isEmpty,
              let output = String(data: result.stdout, encoding: .utf8) else { return nil }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard positivePID(text) != nil else { return nil }
        // Preserve spelling: "01" must not become the reap rule's exact "1".
        return text
    }

    private static func positivePID(_ text: String) -> Int32? {
        guard !text.isEmpty,
              text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int32(text), value > 0 else { return nil }
        return value
    }
}

import Foundation
import Testing
@testable import TranscriptedWritingRuntime

@Suite("Shell probes retain deadlines and reject incomplete process evidence")
struct LlamaShellProbeTests {
    @Test("A launch failure performs no wait, signal or output collection")
    func launchFailureStopsImmediately() throws {
        try requireShellProbeFixtureEnvironment()
        let script = ShellProbeScript(started: false)
        #expect(LlamaShellProbe.execute(driver: script.driver) == .failed)
        #expect(script.trace == [.start])
    }

    @Test("A completed process returns its original status, termination reason and bytes")
    func completedEvidenceIsNotReclassifiedByExecutor() throws {
        try requireShellProbeFixtureEnvironment()
        let evidence = LlamaShellProbe.Completion(status: 17, exitedNormally: false,
                                                  stdout: Data([0xff, 0x00]), stderr: Data("synthetic diagnostic".utf8))
        let script = ShellProbeScript(waits: [true], completion: evidence)
        #expect(LlamaShellProbe.execute(driver: script.driver, timeout: 3.75) == .completed(evidence))
        #expect(script.trace == [.start, .wait(3.75), .completion])
    }

    @Test("A missing completion after a successful wait fails without signaling")
    func missingCompletionFails() throws {
        try requireShellProbeFixtureEnvironment()
        let script = ShellProbeScript(waits: [true])
        #expect(LlamaShellProbe.execute(driver: script.driver) == .failed)
        #expect(script.trace == [.start, .wait(1), .completion])
    }

    @Test("A deadline permanently rejects even empty, partial PID or parent evidence")
    func initialDeadlineNeverCollectsOutput() throws {
        try requireShellProbeFixtureEnvironment()
        for output in ["", "42\n", "1"] {
            let evidence = LlamaShellProbe.Completion(status: 0, exitedNormally: true,
                                                      stdout: Data(output.utf8), stderr: Data())
            let script = ShellProbeScript(waits: [false, true], running: [true], completion: evidence)
            let outcome = LlamaShellProbe.execute(driver: script.driver)
            #expect(outcome == .timedOut)
            #expect(script.trace == [.start, .wait(1), .running(true), .terminate, .wait(0.2)])
            #expect(script.completionCalls == 0, "timeout must never expose late output to either classifier")
            #expect(LlamaShellProbe.listenerPIDs(from: outcome) == nil)
            #expect(LlamaShellProbe.parentPID(from: outcome) == nil)
        }
    }

    @Test("TERM timeout escalates once and final reap cannot erase the original timeout")
    func forceKillRetainsTimeout() throws {
        try requireShellProbeFixtureEnvironment()
        for finalExit in [true, false] {
            let script = ShellProbeScript(waits: [false, false, finalExit], running: [true, true],
                                          completion: shellProbeCompletion("1"))
            #expect(LlamaShellProbe.execute(driver: script.driver, timeout: 2.5) == .timedOut)
            #expect(script.trace == [.start, .wait(2.5), .running(true), .terminate,
                                     .wait(0.2), .running(true), .forceKill, .wait(0.2)])
            #expect(script.completionCalls == 0)
        }
    }

    @Test("Exited-process guards suppress signals without skipping cleanup wait windows")
    func runningGuardsDoNotSkipReapWindows() throws {
        try requireShellProbeFixtureEnvironment()
        let exitedAfterDeadline = ShellProbeScript(waits: [false, true], running: [false])
        #expect(LlamaShellProbe.execute(driver: exitedAfterDeadline.driver) == .timedOut)
        #expect(exitedAfterDeadline.trace == [.start, .wait(1), .running(false), .wait(0.2)])
        for (firstRunning, secondRunning) in [(false, false), (true, false), (false, true)] {
            let script = ShellProbeScript(waits: [false, false, false], running: [firstRunning, secondRunning])
            var expected: [ShellProbeEvent] = [.start, .wait(1), .running(firstRunning)]
            if firstRunning { expected.append(.terminate) }
            expected += [.wait(0.2), .running(secondRunning)]
            if secondRunning { expected.append(.forceKill) }
            expected.append(.wait(0.2))
            #expect(LlamaShellProbe.execute(driver: script.driver) == .timedOut)
            #expect(script.trace == expected)
            #expect(script.completionCalls == 0)
        }
    }

    @Test("Listener output preserves positive ASCII PID order, duplicates and empty separators")
    func listenerPIDSuccessesPreserveSequence() throws {
        try requireShellProbeFixtureEnvironment()
        let cases: [(String, [Int32])] = [
            ("", []), ("\n\r\n", []), ("1", [1]),
            ("42\n7\n", [42, 7]), ("001\n2\n001\n", [1, 2, 1]),
            ("\t42 \r\n\u{00a0}7\t\n", [42, 7]),
            ("2147483647\n", [2_147_483_647])
        ]
        for (text, expected) in cases {
            #expect(LlamaShellProbe.listenerPIDs(from: .completed(shellProbeCompletion(text))) == expected)
        }
    }

    @Test("One malformed listener line rejects the entire PID set")
    func malformedListenerOutputIsNotFilteredIntoSuccess() throws {
        try requireShellProbeFixtureEnvironment()
        let malformed = [" ", "\t\n", "0", "000", "-1", "+1", "2147483648", "-2147483648",
                         "1.0", "1x", "١", "１", "1 2", "12\nwrong\n13", "12\n \n13", "12\n0\n13"]
        for text in malformed {
            #expect(LlamaShellProbe.listenerPIDs(from: .completed(shellProbeCompletion(text))) == nil)
        }
        let invalidUTF8 = LlamaShellProbe.Completion(status: 0, exitedNormally: true,
                                                     stdout: Data([0xff]), stderr: Data())
        #expect(LlamaShellProbe.listenerPIDs(from: .completed(invalidUTF8)) == nil)
    }

    @Test("Exit one means no listeners only for normal termination with zero output bytes")
    func noHitConventionRequiresEmptyEvidence() throws {
        try requireShellProbeFixtureEnvironment()
        #expect(LlamaShellProbe.listenerPIDs(from: .completed(shellProbeCompletion("", status: 1))) == [])
        for text in ["1", " ", "\n", "\t", "synthetic diagnostic"] {
            #expect(LlamaShellProbe.listenerPIDs(from: .completed(shellProbeCompletion(text, status: 1))) == nil)
        }
        for status in [Int32(0), Int32(1)] {
            for diagnostic in [" ", "\n", "synthetic diagnostic"] {
                #expect(LlamaShellProbe.listenerPIDs(from: .completed(shellProbeCompletion("", status: status,
                                                                                         stderr: diagnostic))) == nil)
            }
        }
        let binaryDiagnostic = LlamaShellProbe.Completion(status: 0, exitedNormally: true,
                                                          stdout: Data("42".utf8), stderr: Data([0xff]))
        #expect(LlamaShellProbe.listenerPIDs(from: .completed(binaryDiagnostic)) == nil)
        for outcome in [LlamaShellProbe.Outcome.failed, .timedOut,
                        .completed(shellProbeCompletion("42", status: 2)),
                        .completed(shellProbeCompletion("", status: 1, normally: false)),
                        .completed(shellProbeCompletion("42", normally: false))] {
            #expect(LlamaShellProbe.listenerPIDs(from: outcome) == nil)
        }
    }

    @Test("A parent PID retains its original trimmed ASCII text rather than a canonicalized integer")
    func parentPIDPreservesText() throws {
        try requireShellProbeFixtureEnvironment()
        for (text, expected) in [("1", "1"), (" \t1\r\n", "1"), ("01", "01"),
                                 ("\t001 \r\n", "001"), ("42", "42"), ("2147483647", "2147483647")] {
            #expect(LlamaShellProbe.parentPID(from: .completed(shellProbeCompletion(text))) == expected)
        }
    }

    @Test("Incomplete, diagnostic, multiline or nonpositive parent evidence is refused")
    func parentPIDRejectsAmbiguousEvidence() throws {
        try requireShellProbeFixtureEnvironment()
        for text in ["", " ", "\n", "0", "000", "-1", "+1", "2147483648", "1\n2", "1\r2",
                     "1 2", "1.0", "١", "１", "1x"] {
            #expect(LlamaShellProbe.parentPID(from: .completed(shellProbeCompletion(text))) == nil)
        }
        for status in [Int32(1), Int32(2)] {
            #expect(LlamaShellProbe.parentPID(from: .completed(shellProbeCompletion("1", status: status))) == nil)
        }
        for diagnostic in [" ", "\n", "synthetic diagnostic"] {
            #expect(LlamaShellProbe.parentPID(from: .completed(shellProbeCompletion("1", stderr: diagnostic))) == nil)
        }
        let invalidUTF8 = LlamaShellProbe.Completion(status: 0, exitedNormally: true,
                                                     stdout: Data([0xff]), stderr: Data())
        let binaryDiagnostic = LlamaShellProbe.Completion(status: 0, exitedNormally: true,
                                                          stdout: Data("1".utf8), stderr: Data([0xff]))
        for outcome in [LlamaShellProbe.Outcome.failed, .timedOut, .completed(invalidUTF8), .completed(binaryDiagnostic),
                        .completed(shellProbeCompletion("1", normally: false))] {
            #expect(LlamaShellProbe.parentPID(from: outcome) == nil)
        }
    }
}

private func requireShellProbeFixtureEnvironment() throws {
    try #require(ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1")
}

private func shellProbeCompletion(_ stdout: String, status: Int32 = 0, normally: Bool = true,
                                  stderr: String = "") -> LlamaShellProbe.Completion {
    LlamaShellProbe.Completion(status: status, exitedNormally: normally,
                              stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
}

private enum ShellProbeEvent: Equatable {
    case start
    case wait(TimeInterval)
    case running(Bool)
    case terminate
    case forceKill
    case completion
}

// Only a synchronous script of values. No Process/Pipe/FileHandle, wall-clock
// wait, output collection, signal API, socket or host is instantiated here.
private final class ShellProbeScript {
    var trace: [ShellProbeEvent] = []
    private let started: Bool
    private var waits: [Bool]
    private var running: [Bool]
    private let evidence: LlamaShellProbe.Completion?
    private(set) var completionCalls = 0

    init(started: Bool = true, waits: [Bool] = [], running: [Bool] = [],
         completion: LlamaShellProbe.Completion? = nil) {
        self.started = started; self.waits = waits; self.running = running; self.evidence = completion
    }

    var driver: LlamaShellProbe.Driver {
        LlamaShellProbe.Driver(start: { [self] in
            trace.append(.start)
            return started
        }, waitForExit: { [self] timeout in
            trace.append(.wait(timeout))
            guard !waits.isEmpty else {
                Issue.record("Executor requested an unscripted wait")
                return false
            }
            return waits.removeFirst()
        }, isRunning: { [self] in
            guard !running.isEmpty else {
                Issue.record("Executor requested an unscripted running-state observation")
                return false
            }
            let value = running.removeFirst()
            trace.append(.running(value))
            return value
        }, terminate: { [self] in trace.append(.terminate) },
        forceKill: { [self] in trace.append(.forceKill) },
        completion: { [self] in
            trace.append(.completion)
            completionCalls += 1
            return evidence
        })
    }
}

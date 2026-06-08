import AppKit
import Foundation

@main
struct SlowPastebackSmoke {
    static func main() async {
        let options: SmokeOptions
        do {
            options = try SmokeOptions.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n\n\(SmokeOptions.usage)\n".utf8))
            Foundation.exit(2)
        }

        let scenarios = [
            SmokeScenario(
                id: "production-950ms-slow-target",
                title: "Production fallback keeps fresh dictation for a 950ms Cmd+V reader",
                readDelay: .milliseconds(950),
                restoreDelay: .milliseconds(120),
                fallbackDelay: .nanoseconds(TranscriptedConstants.clipboardRestoreFallbackDelay),
                expectation: .freshInserted,
                probeAutoEnter: true
            ),
            SmokeScenario(
                id: "production-2300ms-near-limit",
                title: "Production fallback keeps fresh dictation near the 2.5s boundary",
                readDelay: .milliseconds(2_300),
                restoreDelay: .milliseconds(120),
                fallbackDelay: .nanoseconds(TranscriptedConstants.clipboardRestoreFallbackDelay),
                expectation: .freshInserted,
                probeAutoEnter: true
            ),
            SmokeScenario(
                id: "old-900ms-control-detects-stale",
                title: "Old 900ms fallback control detects stale clipboard insertion",
                readDelay: .milliseconds(950),
                restoreDelay: .milliseconds(120),
                fallbackDelay: .milliseconds(900),
                expectation: .staleDetected
            ),
            SmokeScenario(
                id: "beyond-production-fallback-detects-stale",
                title: "Reader beyond the production fallback is detected as stale",
                readDelay: .milliseconds(2_700),
                restoreDelay: .milliseconds(120),
                fallbackDelay: .nanoseconds(TranscriptedConstants.clipboardRestoreFallbackDelay),
                expectation: .staleDetected
            ),
            SmokeScenario(
                id: "dispatcher-failure-copies-fresh",
                title: "Paste dispatcher failure leaves fresh dictation copied",
                readDelay: nil,
                restoreDelay: .milliseconds(120),
                fallbackDelay: .nanoseconds(TranscriptedConstants.clipboardRestoreFallbackDelay),
                expectation: .freshCopied,
                dispatcherSucceeds: false
            ),
            SmokeScenario(
                id: "user-copy-restore-safety",
                title: "Clipboard restore does not overwrite a user copy after pasteback",
                readDelay: .milliseconds(300),
                restoreDelay: .milliseconds(120),
                fallbackDelay: .milliseconds(800),
                expectation: .userCopyPreserved,
                userCopyDelay: .milliseconds(500)
            ),
        ]

        var results: [SmokeResult] = []
        for scenario in scenarios {
            results.append(await runScenario(scenario))
        }
        results.append(await runRetryBeforeRestoreScenario())

        let passed = results.filter(\.passed).count
        let failed = results.count - passed
        let shortSummary = failed == 0
            ? "PASS: slow pasteback smoke passed \(passed)/\(results.count) checks."
            : "FAIL: slow pasteback smoke passed \(passed)/\(results.count) checks."

        print(shortSummary)
        for result in results {
            print("\(result.status.rawValue)  \(result.scenarioID)  \(result.detail)")
        }

        do {
            if let jsonOut = options.jsonOut {
                try writeJSON(results: results, shortSummary: shortSummary, to: jsonOut)
            }
            if let markdownOut = options.markdownOut {
                try writeMarkdown(results: results, shortSummary: shortSummary, to: markdownOut)
            }
        } catch {
            FileHandle.standardError.write(Data("Error writing report: \(error.localizedDescription)\n".utf8))
            Foundation.exit(2)
        }

        Foundation.exit(failed == 0 ? 0 : 1)
    }

    @MainActor
    private static func runScenario(_ scenario: SmokeScenario) async -> SmokeResult {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedSlowPasteback-\(scenario.id)-\(UUID().uuidString)"))
        let paster = ClipboardRestoringTextPaster()
        let originalClipboard = "synthetic old clipboard \(UUID().uuidString)"
        let freshDictation = "synthetic fresh dictation \(UUID().uuidString)"
        let userCopy = "synthetic user copy \(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(originalClipboard, forType: .string)

        let startedAt = Date()
        var targetReadTask: Task<String?, Never>?
        var userCopyTask: Task<Void, Never>?
        var autoEnterTask: Task<TimeInterval, Never>?

        let outcome = paster.paste(
            freshDictation,
            pasteboard: pasteboard,
            accessibilityTrusted: { true },
            requestAccessibilityTrust: {},
            pasteDispatcher: {
                if scenario.dispatcherSucceeds {
                    if let readDelay = scenario.readDelay {
                        targetReadTask = Task {
                            try? await Task.sleep(nanoseconds: readDelay.nanoseconds)
                            return await MainActor.run {
                                pasteboard.string(forType: .string)
                            }
                        }
                    }
                    if scenario.probeAutoEnter {
                        autoEnterTask = Task {
                            try? await Task.sleep(nanoseconds: TranscriptedConstants.dictationAutoEnterDelay)
                            await paster.waitForClipboardReadyForAutoEnter()
                            return await MainActor.run {
                                Date().timeIntervalSince(startedAt)
                            }
                        }
                    }
                    if let userCopyDelay = scenario.userCopyDelay {
                        userCopyTask = Task {
                            try? await Task.sleep(nanoseconds: userCopyDelay.nanoseconds)
                            await MainActor.run {
                                pasteboard.clearContents()
                                pasteboard.setString(userCopy, forType: .string)
                            }
                        }
                    }
                }
                return scenario.dispatcherSucceeds
            },
            restoreDelay: scenario.restoreDelay.nanoseconds,
            fallbackRestoreDelay: scenario.fallbackDelay.nanoseconds
        )

        let inserted = await targetReadTask?.value
        await userCopyTask?.value
        let autoEnterReadyAt = await autoEnterTask?.value
        await paster.waitForPendingClipboardRestore()
        let finalClipboard = pasteboard.string(forType: .string)

        return scenario.evaluate(
            outcome: outcome,
            inserted: inserted,
            finalClipboard: finalClipboard,
            originalClipboard: originalClipboard,
            freshDictation: freshDictation,
            userCopy: userCopy,
            autoEnterReadyAt: autoEnterReadyAt
        )
    }

    @MainActor
    private static func runRetryBeforeRestoreScenario() async -> SmokeResult {
        let scenarioID = "production-retry-before-restore"
        let title = "Retry before fallback restore keeps both fake Cmd+V targets fresh"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedSlowPasteback-\(scenarioID)-\(UUID().uuidString)"))
        let paster = ClipboardRestoringTextPaster()
        let originalClipboard = "synthetic retry old clipboard \(UUID().uuidString)"
        let firstDictation = "synthetic first dictation \(UUID().uuidString)"
        let retryDictation = "synthetic retry dictation \(UUID().uuidString)"
        let firstReadDelay = SmokeDelay.milliseconds(180)
        let retryStartDelay = SmokeDelay.milliseconds(320)
        let retryReadDelay = SmokeDelay.milliseconds(950)
        let fallbackDelay = SmokeDelay.nanoseconds(TranscriptedConstants.clipboardRestoreFallbackDelay)
        var firstReadTask: Task<String?, Never>?
        var retryReadTask: Task<String?, Never>?

        func category(for value: String?) -> String {
            switch value {
            case firstDictation:
                return "first_dictation"
            case retryDictation:
                return "retry_dictation"
            case originalClipboard:
                return "old_clipboard"
            case nil:
                return "none"
            default:
                return "unexpected"
            }
        }

        pasteboard.clearContents()
        pasteboard.setString(originalClipboard, forType: .string)

        let firstOutcome = paster.paste(
            firstDictation,
            pasteboard: pasteboard,
            accessibilityTrusted: { true },
            requestAccessibilityTrust: {},
            pasteDispatcher: {
                firstReadTask = Task {
                    try? await Task.sleep(nanoseconds: firstReadDelay.nanoseconds)
                    return await MainActor.run {
                        pasteboard.string(forType: .string)
                    }
                }
                return true
            },
            restoreDelay: SmokeDelay.milliseconds(120).nanoseconds,
            fallbackRestoreDelay: fallbackDelay.nanoseconds
        )

        try? await Task.sleep(nanoseconds: retryStartDelay.nanoseconds)
        let firstInserted = await firstReadTask?.value

        let retryOutcome = paster.paste(
            retryDictation,
            pasteboard: pasteboard,
            accessibilityTrusted: { true },
            requestAccessibilityTrust: {},
            pasteDispatcher: {
                retryReadTask = Task {
                    try? await Task.sleep(nanoseconds: retryReadDelay.nanoseconds)
                    return await MainActor.run {
                        pasteboard.string(forType: .string)
                    }
                }
                return true
            },
            restoreDelay: SmokeDelay.milliseconds(120).nanoseconds,
            fallbackRestoreDelay: fallbackDelay.nanoseconds
        )

        let retryInserted = await retryReadTask?.value
        await paster.waitForPendingClipboardRestore()
        let finalClipboard = pasteboard.string(forType: .string)

        var failures: [String] = []
        if firstOutcome != .pasted {
            failures.append("first paste outcome was \(firstOutcome.diagnosticName)")
        }
        if retryOutcome != .pasted {
            failures.append("retry paste outcome was \(retryOutcome.diagnosticName)")
        }
        if firstInserted != firstDictation {
            failures.append("first target inserted \(category(for: firstInserted))")
        }
        if retryInserted != retryDictation {
            failures.append("retry target inserted \(category(for: retryInserted))")
        }
        if finalClipboard != originalClipboard {
            failures.append("final clipboard was \(category(for: finalClipboard))")
        }

        let status: SmokeStatus = failures.isEmpty ? .pass : .fail
        let insertedCategory = firstInserted == firstDictation && retryInserted == retryDictation
            ? "first_and_retry_fresh"
            : "\(category(for: firstInserted))_then_\(category(for: retryInserted))"
        return SmokeResult(
            scenarioID: scenarioID,
            status: status,
            readDelayMS: retryReadDelay.milliseconds,
            fallbackDelayMS: fallbackDelay.milliseconds,
            insertedCategory: insertedCategory,
            finalClipboardCategory: category(for: finalClipboard),
            autoEnterReadyMS: nil,
            detail: failures.isEmpty ? title : failures.joined(separator: "; ")
        )
    }

    private static func writeJSON(results: [SmokeResult], shortSummary: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = SmokeReport(
            shortSummary: shortSummary,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            results: results
        )
        try encoder.encode(payload).write(to: url)
    }

    private static func writeMarkdown(results: [SmokeResult], shortSummary: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines: [String] = [
            "# Slow Pasteback Smoke",
            "",
            shortSummary,
            "",
            "Synthetic text only. This does not use microphone input, real dictation audio, or private app data.",
            "",
            "| Status | Scenario | Target read | Fallback | Inserted | Final clipboard | Auto Enter ready | Detail |",
            "| --- | --- | ---: | ---: | --- | --- | ---: | --- |",
        ]
        for result in results {
            let readDelay = result.readDelayMS.map { "\($0)ms" } ?? "none"
            let autoEnterReady = result.autoEnterReadyMS.map { "\($0)ms" } ?? "n/a"
            lines.append("| \(result.status.rawValue) | `\(result.scenarioID)` | \(readDelay) | \(result.fallbackDelayMS)ms | \(result.insertedCategory) | \(result.finalClipboardCategory) | \(autoEnterReady) | \(result.detail.replacingOccurrences(of: "|", with: "\\|")) |")
        }
        lines.append("")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct SmokeOptions {
    var jsonOut: URL?
    var markdownOut: URL?

    static let usage = """
    Usage: run-slow-pasteback-smoke.sh [--json-out path] [--markdown-out path]

    Runs a deterministic fake slow Cmd+V target against ClipboardRestoringTextPaster.
    """

    static func parse(_ args: [String]) throws -> SmokeOptions {
        var options = SmokeOptions()
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--json-out":
                guard index + 1 < args.count else { throw SmokeArgumentError("--json-out requires a path") }
                options.jsonOut = URL(fileURLWithPath: args[index + 1])
                index += 2
            case "--markdown-out":
                guard index + 1 < args.count else { throw SmokeArgumentError("--markdown-out requires a path") }
                options.markdownOut = URL(fileURLWithPath: args[index + 1])
                index += 2
            case "-h", "--help":
                print(usage)
                Foundation.exit(0)
            default:
                throw SmokeArgumentError("unknown option \(args[index])")
            }
        }
        return options
    }
}

private struct SmokeArgumentError: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }
    var errorDescription: String? { message }
}

private struct SmokeReport: Encodable {
    let shortSummary: String
    let generatedAt: String
    let results: [SmokeResult]
}

private enum SmokeStatus: String, Encodable {
    case pass = "PASS"
    case fail = "FAIL"
}

private struct SmokeResult: Encodable {
    let scenarioID: String
    let status: SmokeStatus
    let readDelayMS: Int?
    let fallbackDelayMS: Int
    let insertedCategory: String
    let finalClipboardCategory: String
    let autoEnterReadyMS: Int?
    let detail: String

    var passed: Bool { status == .pass }
}

private struct SmokeScenario {
    enum Expectation {
        case freshInserted
        case staleDetected
        case freshCopied
        case userCopyPreserved
    }

    let id: String
    let title: String
    let readDelay: SmokeDelay?
    let restoreDelay: SmokeDelay
    let fallbackDelay: SmokeDelay
    let expectation: Expectation
    var dispatcherSucceeds = true
    var probeAutoEnter = false
    var userCopyDelay: SmokeDelay?

    func evaluate(
        outcome: TextPasteOutcome,
        inserted: String?,
        finalClipboard: String?,
        originalClipboard: String,
        freshDictation: String,
        userCopy: String,
        autoEnterReadyAt: TimeInterval?
    ) -> SmokeResult {
        var failures: [String] = []

        switch expectation {
        case .freshInserted:
            if outcome != .pasted {
                failures.append("paste outcome was \(outcome.diagnosticName)")
            }
            if inserted != freshDictation {
                failures.append("target inserted \(category(for: inserted, original: originalClipboard, fresh: freshDictation, userCopy: userCopy))")
            }
            if finalClipboard != originalClipboard {
                failures.append("final clipboard was \(category(for: finalClipboard, original: originalClipboard, fresh: freshDictation, userCopy: userCopy))")
            }
        case .staleDetected:
            if outcome != .pasted {
                failures.append("paste outcome was \(outcome.diagnosticName)")
            }
            if inserted != originalClipboard {
                failures.append("expected stale-control insertion, saw \(category(for: inserted, original: originalClipboard, fresh: freshDictation, userCopy: userCopy))")
            }
            if finalClipboard != originalClipboard {
                failures.append("final clipboard was \(category(for: finalClipboard, original: originalClipboard, fresh: freshDictation, userCopy: userCopy))")
            }
        case .freshCopied:
            if outcome != .copied("Couldn't paste automatically. The text was copied instead.", reason: .pasteEventCreationFailed) {
                failures.append("paste outcome was \(outcome.diagnosticName)")
            }
            if finalClipboard != freshDictation {
                failures.append("copied fallback left \(category(for: finalClipboard, original: originalClipboard, fresh: freshDictation, userCopy: userCopy))")
            }
        case .userCopyPreserved:
            if outcome != .pasted {
                failures.append("paste outcome was \(outcome.diagnosticName)")
            }
            if inserted != freshDictation {
                failures.append("target inserted \(category(for: inserted, original: originalClipboard, fresh: freshDictation, userCopy: userCopy))")
            }
            if finalClipboard != userCopy {
                failures.append("user copy was overwritten by \(category(for: finalClipboard, original: originalClipboard, fresh: freshDictation, userCopy: userCopy))")
            }
        }

        if probeAutoEnter, let autoEnterReadyAt {
            let readSeconds = Double(readDelay?.nanoseconds ?? 0) / 1_000_000_000
            let fallbackSeconds = Double(fallbackDelay.nanoseconds) / 1_000_000_000
            if autoEnterReadyAt + 0.05 < readSeconds {
                failures.append("Auto Enter became ready before target read")
            }
            if expectation == .freshInserted && autoEnterReadyAt > fallbackSeconds + 0.2 {
                failures.append("Auto Enter waited past fallback readiness")
            }
        }

        let status: SmokeStatus = failures.isEmpty ? .pass : .fail
        let detail = failures.isEmpty ? title : failures.joined(separator: "; ")
        return SmokeResult(
            scenarioID: id,
            status: status,
            readDelayMS: readDelay?.milliseconds,
            fallbackDelayMS: fallbackDelay.milliseconds,
            insertedCategory: category(for: inserted, original: originalClipboard, fresh: freshDictation, userCopy: userCopy),
            finalClipboardCategory: category(for: finalClipboard, original: originalClipboard, fresh: freshDictation, userCopy: userCopy),
            autoEnterReadyMS: autoEnterReadyAt.map { Int(($0 * 1000).rounded()) },
            detail: detail
        )
    }

    private func category(for value: String?, original: String, fresh: String, userCopy: String) -> String {
        switch value {
        case fresh:
            return "fresh_dictation"
        case original:
            return "old_clipboard"
        case userCopy:
            return "user_copy"
        case nil:
            return "none"
        default:
            return "unexpected"
        }
    }
}

private struct SmokeDelay {
    let nanoseconds: UInt64

    var milliseconds: Int {
        Int((Double(nanoseconds) / 1_000_000).rounded())
    }

    static func milliseconds(_ value: Int) -> SmokeDelay {
        SmokeDelay(nanoseconds: UInt64(value) * 1_000_000)
    }

    static func nanoseconds(_ value: UInt64) -> SmokeDelay {
        SmokeDelay(nanoseconds: value)
    }
}

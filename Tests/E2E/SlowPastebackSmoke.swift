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
                title: "Unconfirmed 950ms target keeps fresh dictation copied for manual recovery",
                readDelay: .milliseconds(950),
                restoreDelay: .milliseconds(120),
                fallbackDelay: .nanoseconds(TranscriptedConstants.clipboardRestoreFallbackDelay),
                expectation: .unconfirmedFreshCopied
            ),
            SmokeScenario(
                id: "production-2300ms-near-limit",
                title: "Unconfirmed target near the old fallback limit keeps fresh dictation copied",
                readDelay: .milliseconds(2_300),
                restoreDelay: .milliseconds(120),
                fallbackDelay: .nanoseconds(TranscriptedConstants.clipboardRestoreFallbackDelay),
                expectation: .unconfirmedFreshCopied
            ),
            SmokeScenario(
                id: "old-900ms-control-keeps-fresh-copied",
                title: "Old 900ms fallback control no longer restores away unconfirmed dictation",
                readDelay: .milliseconds(950),
                restoreDelay: .milliseconds(120),
                fallbackDelay: .milliseconds(900),
                expectation: .unconfirmedFreshCopied
            ),
            SmokeScenario(
                id: "beyond-production-fallback-keeps-fresh-copied",
                title: "Reader beyond the old production fallback keeps fresh dictation copied",
                readDelay: .milliseconds(2_700),
                restoreDelay: .milliseconds(120),
                fallbackDelay: .nanoseconds(TranscriptedConstants.clipboardRestoreFallbackDelay),
                expectation: .unconfirmedFreshCopied
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
                readDelay: .milliseconds(0),
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
        results.append(await runRetryWhileRestorePendingScenario())
        results.append(await runCancelPendingRestoreScenario())

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
        var immediateTargetRead: String?
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
                        if readDelay.nanoseconds == 0 {
                            immediateTargetRead = pasteboard.string(forType: .string)
                        } else {
                            targetReadTask = Task {
                                try? await Task.sleep(nanoseconds: readDelay.nanoseconds)
                                return await MainActor.run {
                                    pasteboard.string(forType: .string)
                                }
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

        let inserted: String?
        if let immediateTargetRead {
            inserted = immediateTargetRead
        } else {
            inserted = await targetReadTask?.value
        }
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
    private static func runRetryWhileRestorePendingScenario() async -> SmokeResult {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedSlowPasteback-retry-\(UUID().uuidString)"))
        let paster = ClipboardRestoringTextPaster()
        let originalClipboard = "synthetic original clipboard \(UUID().uuidString)"
        let firstDictation = "synthetic first dictation \(UUID().uuidString)"
        let retryDictation = "synthetic retry dictation \(UUID().uuidString)"
        let readDelay = SmokeDelay.milliseconds(0)
        let retryFallbackDelay = SmokeDelay.milliseconds(800)

        pasteboard.clearContents()
        pasteboard.setString(originalClipboard, forType: .string)

        let firstOutcome = paster.paste(
            firstDictation,
            pasteboard: pasteboard,
            accessibilityTrusted: { true },
            requestAccessibilityTrust: {},
            pasteDispatcher: {
                _ = pasteboard.string(forType: .string)
                return true
            },
            restoreDelay: SmokeDelay.milliseconds(120).nanoseconds,
            fallbackRestoreDelay: SmokeDelay.milliseconds(1_000).nanoseconds
        )
        try? await Task.sleep(nanoseconds: SmokeDelay.milliseconds(50).nanoseconds)

        let retryStartedAt = Date()
        var retryReadTask: Task<String?, Never>?
        var immediateRetryRead: String?
        var autoEnterTask: Task<TimeInterval, Never>?
        let retryOutcome = paster.paste(
            retryDictation,
            pasteboard: pasteboard,
            accessibilityTrusted: { true },
            requestAccessibilityTrust: {},
            pasteDispatcher: {
                if readDelay.nanoseconds == 0 {
                    immediateRetryRead = pasteboard.string(forType: .string)
                } else {
                    retryReadTask = Task {
                        try? await Task.sleep(nanoseconds: readDelay.nanoseconds)
                        return await MainActor.run {
                            pasteboard.string(forType: .string)
                        }
                    }
                }
                autoEnterTask = Task {
                    try? await Task.sleep(nanoseconds: TranscriptedConstants.dictationAutoEnterDelay)
                    await paster.waitForClipboardReadyForAutoEnter()
                    return await MainActor.run {
                        Date().timeIntervalSince(retryStartedAt)
                    }
                }
                return true
            },
            restoreDelay: SmokeDelay.milliseconds(120).nanoseconds,
            fallbackRestoreDelay: retryFallbackDelay.nanoseconds
        )

        let inserted: String?
        if let immediateRetryRead {
            inserted = immediateRetryRead
        } else {
            inserted = await retryReadTask?.value
        }
        let autoEnterReadyAt = await autoEnterTask?.value
        await paster.waitForPendingClipboardRestore()
        let finalClipboard = pasteboard.string(forType: .string)

        var failures: [String] = []
        if firstOutcome != .pasted {
            failures.append("first paste outcome was \(firstOutcome.diagnosticName)")
        }
        if retryOutcome != .pasted {
            failures.append("retry paste outcome was \(retryOutcome.diagnosticName)")
        }
        if inserted != retryDictation {
            failures.append("retry target inserted \(category(for: inserted, original: originalClipboard, fresh: retryDictation, userCopy: nil))")
        }
        if finalClipboard != originalClipboard {
            failures.append("final clipboard was \(category(for: finalClipboard, original: originalClipboard, fresh: retryDictation, userCopy: nil))")
        }
        if let autoEnterReadyAt {
            let readSeconds = Double(readDelay.nanoseconds) / 1_000_000_000
            let fallbackSeconds = Double(retryFallbackDelay.nanoseconds) / 1_000_000_000
            if autoEnterReadyAt + 0.05 < readSeconds {
                failures.append("Auto Enter became ready before retry target read")
            }
            if autoEnterReadyAt > fallbackSeconds + 0.2 {
                failures.append("Auto Enter waited past retry fallback readiness")
            }
        } else {
            failures.append("Auto Enter readiness probe did not complete")
        }

        let status: SmokeStatus = failures.isEmpty ? .pass : .fail
        return SmokeResult(
            scenarioID: "retry-while-restore-pending",
            status: status,
            readDelayMS: readDelay.milliseconds,
            fallbackDelayMS: retryFallbackDelay.milliseconds,
            insertedCategory: category(for: inserted, original: originalClipboard, fresh: retryDictation, userCopy: nil),
            finalClipboardCategory: category(for: finalClipboard, original: originalClipboard, fresh: retryDictation, userCopy: nil),
            autoEnterReadyMS: autoEnterReadyAt.map { Int(($0 * 1000).rounded()) },
            detail: failures.isEmpty
                ? "Retry paste restores the user's original clipboard after the retry target reads fresh dictation"
                : failures.joined(separator: "; ")
        )
    }

    @MainActor
    private static func runCancelPendingRestoreScenario() async -> SmokeResult {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedSlowPasteback-cancel-\(UUID().uuidString)"))
        let paster = ClipboardRestoringTextPaster()
        let originalClipboard = "synthetic original clipboard \(UUID().uuidString)"
        let freshDictation = "synthetic cancellation dictation \(UUID().uuidString)"
        let fallbackDelay = SmokeDelay.milliseconds(400)

        pasteboard.clearContents()
        pasteboard.setString(originalClipboard, forType: .string)

        let outcome = paster.paste(
            freshDictation,
            pasteboard: pasteboard,
            accessibilityTrusted: { true },
            requestAccessibilityTrust: {},
            pasteDispatcher: {
                _ = pasteboard.string(forType: .string)
                return true
            },
            restoreDelay: SmokeDelay.milliseconds(120).nanoseconds,
            fallbackRestoreDelay: fallbackDelay.nanoseconds
        )
        try? await Task.sleep(nanoseconds: SmokeDelay.milliseconds(80).nanoseconds)
        paster.cancelPendingClipboardRestore()

        let waitStartedAt = Date()
        await paster.waitForPendingClipboardRestore()
        let waitMS = Int((Date().timeIntervalSince(waitStartedAt) * 1000).rounded())
        try? await Task.sleep(nanoseconds: fallbackDelay.nanoseconds + SmokeDelay.milliseconds(120).nanoseconds)
        let finalClipboard = pasteboard.string(forType: .string)

        var failures: [String] = []
        if outcome != .pasted {
            failures.append("paste outcome was \(outcome.diagnosticName)")
        }
        if waitMS > 100 {
            failures.append("cancelled restore still waited \(waitMS)ms")
        }
        if finalClipboard != originalClipboard {
            failures.append("cancelled restore left \(category(for: finalClipboard, original: originalClipboard, fresh: freshDictation, userCopy: nil))")
        }

        let status: SmokeStatus = failures.isEmpty ? .pass : .fail
        return SmokeResult(
            scenarioID: "cancel-pending-restore-cleanup",
            status: status,
            readDelayMS: nil,
            fallbackDelayMS: fallbackDelay.milliseconds,
            insertedCategory: "none",
            finalClipboardCategory: category(for: finalClipboard, original: originalClipboard, fresh: freshDictation, userCopy: nil),
            autoEnterReadyMS: nil,
            detail: failures.isEmpty
                ? "Cancellation restores the user's original clipboard immediately and clears delayed restore work"
                : failures.joined(separator: "; ")
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
        case unconfirmedFreshCopied
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
        case .unconfirmedFreshCopied:
            if outcome != .copied("Transcripted tried to paste, but could not confirm the target received it. The text stays copied.", reason: .pasteNotConfirmed) {
                failures.append("paste outcome was \(outcome.diagnosticName)")
            }
            if inserted != freshDictation {
                failures.append("target inserted \(category(for: inserted, original: originalClipboard, fresh: freshDictation, userCopy: userCopy))")
            }
            if finalClipboard != freshDictation {
                failures.append("unconfirmed paste left \(category(for: finalClipboard, original: originalClipboard, fresh: freshDictation, userCopy: userCopy))")
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

}

private func category(for value: String?, original: String, fresh: String, userCopy: String?) -> String {
    if value == fresh {
        return "fresh_dictation"
    }
    if value == original {
        return "old_clipboard"
    }
    if let userCopy, value == userCopy {
        return "user_copy"
    }
    if value == nil {
        return "none"
    }
    return "unexpected"
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

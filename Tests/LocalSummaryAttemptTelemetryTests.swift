import Foundation

func testLocalSummaryAttemptTelemetry() {
    runSuite("Local summary attempt telemetry emits one intent and one terminal") {
        let result = runLocalSummaryTelemetryHarness()
        assertEqual(
            result.status,
            0,
            "standalone telemetry policy harness should pass\n\(result.output)"
        )
    }

    runSuite("Local summary settings flow uses only the canonical lifecycle") {
        let settings = readLocalSummaryTelemetryRepoFile(
            "Sources/UI/Settings/TranscriptedSettingsView.swift"
        )
        let helper = readLocalSummaryTelemetryRepoFile(
            "Sources/UI/Settings/LocalSummaryAttemptTelemetry.swift"
        )
        let taxonomy = readLocalSummaryTelemetryRepoFile("Resources/analytics-events.psv")

        assertEqual(
            settings.components(separatedBy: "telemetryAttempt.intent(").count - 1,
            1,
            "each accepted summary attempt should emit one canonical intent"
        )
        assertTrue(
            settings.contains("telemetryAttempt.terminal("),
            "every accepted summary outcome should route through the one-terminal policy"
        )
        assertFalse(
            settings.contains("trackLocalSummaryAbandoned"),
            "summary terminals should not also emit generic workflow abandonment"
        )
        assertFalse(
            settings.contains("trackLocalSummaryAnalytics"),
            "the retired free-form summary tracker should not bypass the stateful policy"
        )
        assertTrue(
            settings.contains("cancelLocalSummaryJobs(reason: .featureDisabled)"),
            "feature disable should mark the owned summary tasks before cancellation"
        )
        assertTrue(
            settings.contains("cancelLocalSummaryJobs(reason: .providerChanged)"),
            "provider changes should mark the owned summary tasks before cancellation"
        )
        assertFalse(
            settings.contains("cancellationStage = localMeetingSummariesEnabled ? nil : stage"),
            "terminal cancellation must not be inferred from current feature state"
        )
        assertTrue(
            settings.contains("homeLocalSummaryCancellationRegistry.register("),
            "each accepted task should register its token-scoped terminal arbiter"
        )
        assertTrue(
            settings.contains("outcomeArbiter.resolve("),
            "the detached task should atomically resolve its terminal before MainActor delivery"
        )
        assertFalse(
            settings.contains("isCancellationRequested("),
            "MainActor must not relabel a terminal by consulting late cancellation state"
        )
        assertTrue(
            helper.contains("userInfo[NSMultipleUnderlyingErrorsKey]"),
            "nested Foundation errors should use the canonical multi-error key"
        )
        assertFalse(
            helper.contains("\"NSMultipleUnderlyingErrors\""),
            "the incorrect multi-error key literal must not return"
        )
        assertFalse(
            taxonomy.contains("local_meeting_summary_started|"),
            "legacy summary starts should be historical-only"
        )
        assertFalse(
            taxonomy.contains("local_meeting_summary_completed|"),
            "legacy summary completions should be historical-only"
        )
        assertFalse(
            taxonomy.contains("local_meeting_summary_failed|"),
            "legacy summary failures should be historical-only"
        )
    }
}

private struct LocalSummaryTelemetryHarnessResult {
    let status: Int32
    let output: String
}

private func runLocalSummaryTelemetryHarness() -> LocalSummaryTelemetryHarnessResult {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("local-summary-telemetry-\(UUID().uuidString)", isDirectory: true)
    let harnessURL = temporaryDirectory.appendingPathComponent("Harness.swift")
    let binaryURL = temporaryDirectory.appendingPathComponent("harness")
    let outputURL = temporaryDirectory.appendingPathComponent("output.log")
    let moduleCacheURL = temporaryDirectory.appendingPathComponent("swift-module-cache", isDirectory: true)
    let clangCacheURL = temporaryDirectory.appendingPathComponent("clang-module-cache", isDirectory: true)

    do {
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: moduleCacheURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: clangCacheURL, withIntermediateDirectories: true)
        try localSummaryTelemetryHarnessSource.write(to: harnessURL, atomically: true, encoding: .utf8)
        fileManager.createFile(atPath: outputURL.path, contents: nil)
    } catch {
        return LocalSummaryTelemetryHarnessResult(status: -127, output: "setup failed: \(error)")
    }
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    let helperURL = repoFixtureURL("Sources/UI/Settings/LocalSummaryAttemptTelemetry.swift")
    var environment = ProcessInfo.processInfo.environment
    environment["SWIFT_MODULE_CACHE_PATH"] = moduleCacheURL.path
    environment["CLANG_MODULE_CACHE_PATH"] = clangCacheURL.path

    let compileResult = runLocalSummaryTelemetryProcess(
        executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: ["swiftc", helperURL.path, harnessURL.path, "-o", binaryURL.path],
        environment: environment,
        outputURL: outputURL
    )
    guard compileResult.status == 0 else { return compileResult }

    return runLocalSummaryTelemetryProcess(
        executableURL: binaryURL,
        arguments: [],
        environment: environment,
        outputURL: outputURL
    )
}

private func runLocalSummaryTelemetryProcess(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    outputURL: URL
) -> LocalSummaryTelemetryHarnessResult {
    guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
        return LocalSummaryTelemetryHarnessResult(status: -127, output: "could not open harness output")
    }
    defer { try? outputHandle.close() }
    _ = try? outputHandle.seekToEnd()

    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = repoFixtureURL(".")
    process.standardOutput = outputHandle
    process.standardError = outputHandle

    do {
        try process.run()
        process.waitUntilExit()
        try? outputHandle.synchronize()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return LocalSummaryTelemetryHarnessResult(status: process.terminationStatus, output: output)
    } catch {
        return LocalSummaryTelemetryHarnessResult(status: -127, output: String(describing: error))
    }
}

private func readLocalSummaryTelemetryRepoFile(_ path: String) -> String {
    (try? String(contentsOf: repoFixtureURL(path), encoding: .utf8)) ?? ""
}

private let localSummaryTelemetryHarnessSource = #"""
import Foundation

enum LocalMeetingSummaryError: Error {
    case emptyTranscript
    case insufficientMemory(availableGB: Int, requiredGB: Int)
    case runtimeUnavailable
    case appleFoundationUnavailable(reason: String)
    case missingBundledRunner
    case transcriptChanged
    case processTimedOut(label: String)
    case processFailed(label: String, exitCode: Int32, detail: String)
    case outputMissing(label: String)
}

struct HarnessError: Error {}

final class CyclicNSError: NSError {
    var nestedError: Error?
    var additionalErrors: [Error] = []

    override var userInfo: [String: Any] {
        var info: [String: Any] = [:]
        if let nestedError {
            info[NSUnderlyingErrorKey] = nestedError
        }
        if !additionalErrors.isEmpty {
            info[NSMultipleUnderlyingErrorsKey] = additionalErrors
        }
        return info
    }

    init(domain: String, code: Int) {
        super.init(domain: domain, code: code, userInfo: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }
}

// LocalSummaryAttemptTelemetry is @MainActor (all real usage is confined to
// the settings view's MainActor isolation). Only the `main()` entry point of
// an executable gets implicit MainActor isolation; the private static
// helpers below need the annotation explicitly to keep calling it
// synchronously without threading `await` through this whole harness.
@MainActor
@main
struct Harness {
    static func main() {
        testCardinalityAndPayloads()
        testTerminalOutcomeOwnership()
        testFailureTaxonomy()
    }

    private static func testCardinalityAndPayloads() {
        let successAttempt = LocalSummaryAttemptTelemetry(
            providerRawValue: "gemmaMLX",
            summaryAction: .generate,
            setupReady: true
        )
        expect(
            successAttempt.terminal(.success(chunkCount: 1), durationBucket: "lt_10s") == nil,
            "terminal must not emit before intent"
        )
        let intent = require(successAttempt.intent(queueDepth: 2), "first intent")
        expect(intent.event == "local_summary_requested", "intent event")
        expect(intent.properties["provider"] == "gemmaMLX", "provider enum")
        expect(intent.properties["runtime"] == "mlx", "runtime family")
        expect(intent.properties["setup_ready"] == "true", "setup readiness")
        expect(intent.properties["summary_action"] == "generate", "summary action")
        expect(intent.properties["queue_depth_bucket"] == "2_3", "queue bucket")
        expect(successAttempt.intent(queueDepth: 2) == nil, "duplicate intent suppressed")

        let success = require(
            successAttempt.terminal(.success(chunkCount: 3), durationBucket: "30_119s"),
            "success terminal"
        )
        expect(success.event == "local_summary_finished", "success event")
        expect(success.properties["result"] == "success", "success result")
        expect(success.properties["stage"] == "complete", "success stage")
        expect(success.properties["chunk_count_bucket"] == "2_3", "chunk bucket")
        expect(success.properties["setup_ready"] == "true", "terminal setup readiness")
        expect(
            successAttempt.terminal(.failure(kind: .unknown, stage: .generate), durationBucket: "30_119s") == nil,
            "second terminal suppressed"
        )

        let failedAttempt = LocalSummaryAttemptTelemetry(
            providerRawValue: "gemmaMLX",
            summaryAction: .generate,
            setupReady: true
        )
        _ = require(failedAttempt.intent(queueDepth: 1), "failure intent")
        let failed = require(
            failedAttempt.terminal(
                .failure(kind: .processFailed, stage: .generate),
                durationBucket: "30_119s"
            ),
            "failure terminal"
        )
        expect(failed.event == "local_summary_failed", "failure event")
        expect(failed.properties["result"] == "failure", "failure result")
        expect(failed.properties["failure_kind"] == "process_failed", "failure reason")
        expect(failed.properties["stage"] == "generate", "failure stage")
        expect(
            failedAttempt.terminal(.cancelled(stage: .generate), durationBucket: "30_119s") == nil,
            "failure terminal is irrevocable"
        )

        let blockedAttempt = LocalSummaryAttemptTelemetry(
            providerRawValue: "appleFoundation",
            summaryAction: .regenerate,
            setupReady: false
        )
        _ = require(blockedAttempt.intent(queueDepth: 0), "blocked intent")
        let blocked = require(
            blockedAttempt.terminal(
                .blocked(kind: .appleFoundationUnavailable, stage: .preflight),
                durationBucket: "lt_10s"
            ),
            "blocked terminal"
        )
        expect(blocked.event == "local_summary_failed", "blocked terminal event")
        expect(blocked.properties["result"] == "blocked", "blocked result")
        expect(blocked.properties["failure_kind"] == "apple_foundation_unavailable", "blocked reason")
        expect(blocked.properties["runtime"] == "foundation_models", "Apple runtime family")
        expect(blocked.properties["setup_ready"] == "false", "blocked setup readiness")

        let cancelledAttempt = LocalSummaryAttemptTelemetry(
            providerRawValue: "gemmaMLX",
            summaryAction: .generate,
            setupReady: true
        )
        _ = require(cancelledAttempt.intent(queueDepth: 0), "cancel intent")
        let cancelled = require(
            cancelledAttempt.terminal(.cancelled(stage: .generate), durationBucket: "10_29s"),
            "cancel terminal"
        )
        expect(cancelled.event == "local_summary_cancelled", "cancel event")
        expect(cancelled.properties["result"] == "cancelled", "cancel result")

        let safeKeys: Set<String> = [
            "chunk_count_bucket", "duration_bucket", "failure_kind", "provider", "queue_depth_bucket",
            "result", "runtime", "setup_ready", "stage", "summary_action",
        ]
        expect(Set(intent.properties.keys).isSubset(of: safeKeys), "intent keys stay coarse")
        expect(Set(success.properties.keys).isSubset(of: safeKeys), "terminal keys stay coarse")
        expect(Set(failed.properties.keys).isSubset(of: safeKeys), "failure keys stay coarse")
        expect(Set(blocked.properties.keys).isSubset(of: safeKeys), "blocked keys stay coarse")
    }

    private static func testFailureTaxonomy() {
        expectClassification(
            LocalMeetingSummaryError.emptyTranscript,
            .failure(kind: .emptyTranscript, stage: .input)
        )
        expectClassification(
            LocalMeetingSummaryError.insufficientMemory(availableGB: 8, requiredGB: 12),
            .failure(kind: .insufficientMemory, stage: .setup)
        )
        expectClassification(
            LocalMeetingSummaryError.runtimeUnavailable,
            .failure(kind: .runtimeUnavailable, stage: .setup)
        )
        expectClassification(
            LocalMeetingSummaryError.appleFoundationUnavailable(reason: "private"),
            .failure(kind: .appleFoundationUnavailable, stage: .setup)
        )
        expectClassification(
            LocalMeetingSummaryError.missingBundledRunner,
            .failure(kind: .missingRunner, stage: .setup)
        )
        expectClassification(
            LocalMeetingSummaryError.transcriptChanged,
            .failure(kind: .transcriptChanged, stage: .write)
        )
        expectClassification(
            LocalMeetingSummaryError.processTimedOut(label: "private"),
            .failure(kind: .timeout, stage: .generate)
        )
        expectClassification(
            LocalMeetingSummaryError.processFailed(
                label: "private",
                exitCode: 1,
                detail: "/private/path"
            ),
            .failure(kind: .processFailed, stage: .generate)
        )
        expectClassification(
            LocalMeetingSummaryError.outputMissing(label: "private"),
            .failure(kind: .outputMissing, stage: .generate)
        )

        let wrapped = NSError(
            domain: "wrapper",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: LocalMeetingSummaryError.processTimedOut(label: "private")]
        )
        expectClassification(wrapped, .failure(kind: .timeout, stage: .generate))
        expectClassification(
            NSError(domain: NSCocoaErrorDomain, code: 260),
            .failure(kind: .fileNotFound, stage: .fileIO)
        )
        expectClassification(
            NSError(domain: NSCocoaErrorDomain, code: 513),
            .failure(kind: .permissionDenied, stage: .fileIO)
        )
        expectClassification(
            NSError(domain: NSCocoaErrorDomain, code: 640),
            .failure(kind: .diskFull, stage: .write)
        )
        expectClassification(
            NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOEXEC.rawValue)),
            .failure(kind: .runtimeUnavailable, stage: .setup)
        )
        expectClassification(
            NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EIO.rawValue)),
            .failure(kind: .ioError, stage: .fileIO)
        )
        expectClassification(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
            .failure(kind: .networkUnavailable, stage: .setup)
        )
        expectClassification(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
            .cancelled(stage: .setup)
        )

        let cocoaReadWrappingPOSIXCancellation = NSError(
            domain: NSCocoaErrorDomain,
            code: 256,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(POSIXErrorCode.ECANCELED.rawValue)
                ),
            ]
        )
        expectClassification(cocoaReadWrappingPOSIXCancellation, .cancelled(stage: .generate))

        let cocoaWriteWrappingURLCancellation = NSError(
            domain: NSCocoaErrorDomain,
            code: 512,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorCancelled
                ),
            ]
        )
        expectClassification(cocoaWriteWrappingURLCancellation, .cancelled(stage: .setup))

        let cocoaReadWrappingDiskFull = NSError(
            domain: NSCocoaErrorDomain,
            code: 256,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(POSIXErrorCode.ENOSPC.rawValue)
                ),
            ]
        )
        expectClassification(cocoaReadWrappingDiskFull, .failure(kind: .diskFull, stage: .write))

        let cocoaWriteWrappingPermission = NSError(
            domain: NSCocoaErrorDomain,
            code: 512,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(POSIXErrorCode.EACCES.rawValue)
                ),
            ]
        )
        expectClassification(
            cocoaWriteWrappingPermission,
            .failure(kind: .permissionDenied, stage: .fileIO)
        )

        let multipleUnderlyingErrors = NSError(
            domain: NSCocoaErrorDomain,
            code: 256,
            userInfo: [
                NSMultipleUnderlyingErrorsKey: [
                    NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EIO.rawValue)),
                    NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOSPC.rawValue)),
                ],
            ]
        )
        expectClassification(multipleUnderlyingErrors, .failure(kind: .diskFull, stage: .write))

        let equalPrecedenceUsesStableOrder = NSError(
            domain: NSCocoaErrorDomain,
            code: 256,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(POSIXErrorCode.EACCES.rawValue)
                ),
                NSMultipleUnderlyingErrorsKey: [
                    NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOSPC.rawValue)),
                ],
            ]
        )
        expectClassification(
            equalPrecedenceUsesStableOrder,
            .failure(kind: .permissionDenied, stage: .fileIO)
        )

        let cyclic = CyclicNSError(domain: NSCocoaErrorDomain, code: 256)
        cyclic.nestedError = cyclic
        expectClassification(cyclic, .failure(kind: .ioError, stage: .fileIO))

        var deeplyWrappedDiskFull: Error = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.ENOSPC.rawValue)
        )
        for _ in 0..<64 {
            deeplyWrappedDiskFull = NSError(
                domain: NSCocoaErrorDomain,
                code: 256,
                userInfo: [NSUnderlyingErrorKey: deeplyWrappedDiskFull]
            )
        }
        expectClassification(
            deeplyWrappedDiskFull,
            .failure(kind: .diskFull, stage: .write)
        )

        var deeplyWrappedCancellation: Error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled
        )
        for index in 0..<64 {
            deeplyWrappedCancellation = NSError(
                domain: NSCocoaErrorDomain,
                code: index.isMultiple(of: 2) ? 256 : 512,
                userInfo: [NSUnderlyingErrorKey: deeplyWrappedCancellation]
            )
        }
        expectClassification(deeplyWrappedCancellation, .cancelled(stage: .setup))

        var wideUnderlyingErrors: [Error] = (0..<80).map { _ in
            NSError(domain: NSCocoaErrorDomain, code: 256)
        }
        wideUnderlyingErrors.append(
            NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(POSIXErrorCode.EACCES.rawValue)
            )
        )
        let widelyWrappedPermission = NSError(
            domain: NSCocoaErrorDomain,
            code: 512,
            userInfo: [NSMultipleUnderlyingErrorsKey: wideUnderlyingErrors]
        )
        expectClassification(
            widelyWrappedPermission,
            .failure(kind: .permissionDenied, stage: .fileIO)
        )

        let cycleStart = CyclicNSError(domain: NSCocoaErrorDomain, code: 256)
        let cycleEnd = CyclicNSError(domain: NSCocoaErrorDomain, code: 512)
        cycleStart.nestedError = cycleEnd
        cycleEnd.nestedError = cycleStart
        cycleEnd.additionalErrors = [
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
        ]
        expectClassification(cycleStart, .cancelled(stage: .setup))

        var beyondTraversalBudget: Error = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.ENOSPC.rawValue)
        )
        for _ in 0..<300 {
            beyondTraversalBudget = NSError(
                domain: NSCocoaErrorDomain,
                code: 256,
                userInfo: [NSUnderlyingErrorKey: beyondTraversalBudget]
            )
        }
        expectClassification(
            beyondTraversalBudget,
            .failure(kind: .unknown, stage: .generate)
        )

        let decoding = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "private")
        )
        expectClassification(decoding, .failure(kind: .invalidOutput, stage: .generate))
        expectClassification(HarnessError(), .failure(kind: .unknown, stage: .generate))
    }

    private static func testTerminalOutcomeOwnership() {
        let summaryID = "summary-a"
        var registry = LocalSummaryCancellationRegistry()

        let completedSuccessToken = UUID()
        let completedSuccessArbiter = LocalSummaryTerminalOutcomeArbiter()
        registry.register(
            summaryID: summaryID,
            taskToken: completedSuccessToken,
            arbiter: completedSuccessArbiter
        )
        let completedSuccess = completedSuccessArbiter.resolve(
            Result<String, Error>.success("saved")
        )
        expect(
            !registry.request(
                summaryID: summaryID,
                taskToken: completedSuccessToken,
                reason: .featureDisabled
            ),
            "a disable toggle cannot relabel success after the task terminal won"
        )
        switch completedSuccess {
        case .success(let value):
            expect(value == "saved", "completed success remains success after the toggle")
        default:
            fatalError("completed success was relabelled")
        }

        let completedFailureToken = UUID()
        let completedFailureArbiter = LocalSummaryTerminalOutcomeArbiter()
        registry.register(
            summaryID: summaryID,
            taskToken: completedFailureToken,
            arbiter: completedFailureArbiter
        )
        let completedFailure = completedFailureArbiter.resolve(
            Result<String, Error>.failure(HarnessError())
        )
        expect(
            !registry.request(
                summaryID: summaryID,
                taskToken: completedFailureToken,
                reason: .providerChanged
            ),
            "a provider toggle cannot relabel failure after the task terminal won"
        )
        switch completedFailure {
        case .failure(let error):
            expect(error is HarnessError, "completed failure remains the original failure")
        default:
            fatalError("completed failure was relabelled")
        }

        let cancellationFirstToken = UUID()
        let cancellationFirstArbiter = LocalSummaryTerminalOutcomeArbiter()
        registry.register(
            summaryID: summaryID,
            taskToken: cancellationFirstToken,
            arbiter: cancellationFirstArbiter
        )
        expect(
            registry.request(
                summaryID: summaryID,
                taskToken: cancellationFirstToken,
                reason: .providerChanged
            ),
            "token-scoped cancellation should win while the task is still pending"
        )
        let cancellationFirst = cancellationFirstArbiter.resolve(
            Result<String, Error>.success("saved-after-cancel")
        )
        switch cancellationFirst {
        case .cancelled(let reason, let underlyingError):
            expect(reason == .providerChanged, "cancellation keeps its owned reason")
            expect(underlyingError == nil, "successful work after cancellation adds no raw error")
        default:
            fatalError("pending cancellation did not own the terminal")
        }

        expect(
            !registry.request(
                summaryID: summaryID,
                taskToken: UUID(),
                reason: .featureDisabled
            ),
            "a cancellation token must not affect another task identity"
        )
    }

    private static func expectClassification(
        _ error: Error,
        _ expected: LocalSummaryTelemetryErrorClassification
    ) {
        expect(LocalSummaryTelemetryFailureClassifier.classify(error) == expected, "classification \(expected)")
    }

    private static func require<T>(_ value: T?, _ message: String) -> T {
        guard let value else { fatalError(message) }
        return value
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
"""#

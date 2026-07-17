import Foundation

struct LocalSummaryTelemetryEmission: Equatable {
    let event: String
    let properties: [String: String]
}

enum LocalSummaryTelemetryStage: String, Equatable {
    case preflight
    case setup
    case input
    case generate
    case write
    case complete
    case fileIO = "file_io"
}

enum LocalSummaryTelemetryFailureKind: String, Equatable {
    case emptyTranscript = "empty_transcript"
    case insufficientMemory = "insufficient_memory"
    case runtimeUnavailable = "runtime_unavailable"
    case appleFoundationUnavailable = "apple_foundation_unavailable"
    case missingRunner = "missing_runner"
    case transcriptChanged = "transcript_changed"
    case timeout
    case processFailed = "process_failed"
    case outputMissing = "output_missing"
    case transcriptUnavailable = "transcript_unavailable"
    case dictationActive = "dictation_active"
    case meetingRecording = "meeting_recording"
    case modelsPreparing = "models_preparing"
    case summaryModelPreparing = "summary_model_preparing"
    case meetingWorkActive = "meeting_work_active"
    case speakerReviewPending = "speaker_review_pending"
    case blocked
    case fileNotFound = "file_not_found"
    case permissionDenied = "permission_denied"
    case diskFull = "disk_full"
    case ioError = "io_error"
    case invalidOutput = "invalid_output"
    case networkUnavailable = "network_unavailable"
    case unknown
}

enum LocalSummaryTelemetryErrorClassification: Equatable {
    case cancelled(stage: LocalSummaryTelemetryStage)
    case failure(kind: LocalSummaryTelemetryFailureKind, stage: LocalSummaryTelemetryStage)
}

final class LocalSummaryAttemptTelemetry {
    enum SummaryAction: String {
        case generate
        case regenerate
    }

    enum Outcome: Equatable {
        case success(chunkCount: Int)
        case failure(kind: LocalSummaryTelemetryFailureKind, stage: LocalSummaryTelemetryStage)
        case blocked(kind: LocalSummaryTelemetryFailureKind, stage: LocalSummaryTelemetryStage)
        case cancelled(stage: LocalSummaryTelemetryStage)
    }

    private enum Provider: String {
        case gemmaMLX
        case appleFoundation
        case unknown

        init(rawValueOrUnknown rawValue: String) {
            self = Provider(rawValue: rawValue) ?? .unknown
        }

        var runtime: String {
            switch self {
            case .gemmaMLX:
                return "mlx"
            case .appleFoundation:
                return "foundation_models"
            case .unknown:
                return "unknown"
            }
        }
    }

    static let requestedEvent = "local_summary_requested"
    static let finishedEvent = "local_summary_finished"
    static let failedEvent = "local_summary_failed"
    static let cancelledEvent = "local_summary_cancelled"

    private let provider: Provider
    private let summaryAction: SummaryAction
    private let setupReady: Bool
    private var didEmitIntent = false
    private var didEmitTerminal = false

    init(providerRawValue: String, summaryAction: SummaryAction, setupReady: Bool) {
        provider = Provider(rawValueOrUnknown: providerRawValue)
        self.summaryAction = summaryAction
        self.setupReady = setupReady
    }

    func intent(queueDepth: Int) -> LocalSummaryTelemetryEmission? {
        guard !didEmitIntent, !didEmitTerminal else { return nil }
        didEmitIntent = true

        var properties = baseProperties
        properties["queue_depth_bucket"] = Self.queueDepthBucket(queueDepth)
        return LocalSummaryTelemetryEmission(event: Self.requestedEvent, properties: properties)
    }

    func terminal(
        _ outcome: Outcome,
        durationBucket: String
    ) -> LocalSummaryTelemetryEmission? {
        guard didEmitIntent, !didEmitTerminal else { return nil }
        didEmitTerminal = true

        var properties = baseProperties
        properties["duration_bucket"] = durationBucket

        let event: String
        switch outcome {
        case .success(let chunkCount):
            event = Self.finishedEvent
            properties["chunk_count_bucket"] = Self.countBucket(chunkCount)
            properties["result"] = "success"
            properties["stage"] = LocalSummaryTelemetryStage.complete.rawValue
        case .failure(let failureKind, let stage):
            event = Self.failedEvent
            properties["failure_kind"] = failureKind.rawValue
            properties["result"] = "failure"
            properties["stage"] = stage.rawValue
        case .blocked(let failureKind, let stage):
            event = Self.failedEvent
            properties["failure_kind"] = failureKind.rawValue
            properties["result"] = "blocked"
            properties["stage"] = stage.rawValue
        case .cancelled(let stage):
            event = Self.cancelledEvent
            properties["result"] = "cancelled"
            properties["stage"] = stage.rawValue
        }

        return LocalSummaryTelemetryEmission(event: event, properties: properties)
    }

    private var baseProperties: [String: String] {
        [
            "provider": provider.rawValue,
            "runtime": provider.runtime,
            "setup_ready": setupReady ? "true" : "false",
            "summary_action": summaryAction.rawValue,
        ]
    }

    private static func countBucket(_ count: Int) -> String {
        switch count {
        case ..<1:
            return "0"
        case 1:
            return "1"
        case 2...3:
            return "2_3"
        case 4...9:
            return "4_9"
        default:
            return "10_plus"
        }
    }

    private static func queueDepthBucket(_ depth: Int) -> String {
        switch depth {
        case ..<1:
            return "0"
        case 1:
            return "1"
        case 2...3:
            return "2_3"
        default:
            return "4_plus"
        }
    }
}

enum LocalSummaryCancellationReason: Equatable {
    case featureDisabled
    case providerChanged
}

enum LocalSummaryAttemptTaskCompletion<Success>: @unchecked Sendable {
    case success(Success)
    case failure(Error)
    case cancelled(reason: LocalSummaryCancellationReason, underlyingError: Error?)
}

final class LocalSummaryTerminalOutcomeArbiter: @unchecked Sendable {
    private enum State {
        case pending
        case cancellationRequested(LocalSummaryCancellationReason)
        case resolved
    }

    private let lock = NSLock()
    private var state: State = .pending

    @discardableResult
    func requestCancellation(reason: LocalSummaryCancellationReason) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard case .pending = state else { return false }
        state = .cancellationRequested(reason)
        return true
    }

    func resolve<Success>(
        _ result: Result<Success, Error>
    ) -> LocalSummaryAttemptTaskCompletion<Success> {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .pending:
            state = .resolved
            switch result {
            case .success(let value):
                return .success(value)
            case .failure(let error):
                return .failure(error)
            }
        case .cancellationRequested(let reason):
            state = .resolved
            let underlyingError: Error?
            switch result {
            case .success:
                underlyingError = nil
            case .failure(let error):
                underlyingError = error
            }
            return .cancelled(reason: reason, underlyingError: underlyingError)
        case .resolved:
            preconditionFailure("Local summary terminal outcome resolved more than once")
        }
    }
}

struct LocalSummaryCancellationRegistry {
    typealias Reason = LocalSummaryCancellationReason

    private struct TaskIdentity: Hashable {
        let summaryID: String
        let taskToken: UUID
    }

    private var arbiters: [TaskIdentity: LocalSummaryTerminalOutcomeArbiter] = [:]

    mutating func register(
        summaryID: String,
        taskToken: UUID,
        arbiter: LocalSummaryTerminalOutcomeArbiter
    ) {
        arbiters[TaskIdentity(summaryID: summaryID, taskToken: taskToken)] = arbiter
    }

    @discardableResult
    func request(
        summaryID: String,
        taskToken: UUID,
        reason: Reason
    ) -> Bool {
        arbiters[TaskIdentity(summaryID: summaryID, taskToken: taskToken)]?
            .requestCancellation(reason: reason) ?? false
    }

    mutating func remove(summaryID: String, taskToken: UUID) {
        arbiters[TaskIdentity(summaryID: summaryID, taskToken: taskToken)] = nil
    }
}

enum LocalSummaryTelemetryFailureClassifier {
    private static let maximumTraversalNodeCount = 256

    private struct PendingError {
        let error: Error
        let nsError: NSError

        init(_ error: Error) {
            self.error = error
            nsError = error as NSError
        }

        var identity: ObjectIdentifier {
            ObjectIdentifier(nsError)
        }
    }

    static func classify(_ error: Error) -> LocalSummaryTelemetryErrorClassification {
        var pending: [PendingError] = []
        var enqueuedNSErrorIDs = Set<ObjectIdentifier>()
        var traversalWasTruncated = false
        _ = enqueue(
            error,
            pending: &pending,
            enqueuedNSErrorIDs: &enqueuedNSErrorIDs,
            traversalWasTruncated: &traversalWasTruncated
        )
        var nextIndex = 0
        var visitedNSErrorIDs = Set<ObjectIdentifier>()
        var bestClassification: LocalSummaryTelemetryErrorClassification?
        var bestPrecedence = Int.min

        // Precedence is deterministic: cancellation, then a specific failure,
        // then generic I/O, then unknown. Equal precedence keeps breadth-first
        // order: the outer error, NSUnderlyingErrorKey, then the multiple-error
        // array in its original order. This lets a precise nested cause replace
        // Cocoa 256/512 or POSIX EIO without making wrapper order unpredictable.
        while nextIndex < pending.count {
            let candidate = pending[nextIndex]
            nextIndex += 1

            guard visitedNSErrorIDs.insert(candidate.identity).inserted else {
                continue
            }

            if let classification = classifyDirect(candidate.error, nsError: candidate.nsError) {
                let precedence = precedence(of: classification)
                if precedence > bestPrecedence {
                    bestClassification = classification
                    bestPrecedence = precedence
                }
            }

            if let underlying = candidate.nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                _ = enqueue(
                    underlying,
                    pending: &pending,
                    enqueuedNSErrorIDs: &enqueuedNSErrorIDs,
                    traversalWasTruncated: &traversalWasTruncated
                )
            }
            if let underlyingValues = candidate.nsError.userInfo[NSMultipleUnderlyingErrorsKey] as? [Any] {
                for value in underlyingValues {
                    guard let underlying = value as? Error else { continue }
                    guard enqueue(
                        underlying,
                        pending: &pending,
                        enqueuedNSErrorIDs: &enqueuedNSErrorIDs,
                        traversalWasTruncated: &traversalWasTruncated
                    ) else {
                        break
                    }
                }
            }
        }

        // A bounded traversal must never promote a generic wrapper merely
        // because a more specific cause fell outside the budget. Cancellation
        // is safe to keep because it has the highest possible precedence;
        // every other truncated graph reports unknown rather than false detail.
        if traversalWasTruncated {
            if let bestClassification,
               case .cancelled = bestClassification {
                return bestClassification
            }
            return .failure(kind: .unknown, stage: .generate)
        }

        return bestClassification ?? .failure(kind: .unknown, stage: .generate)
    }

    @discardableResult
    private static func enqueue(
        _ error: Error,
        pending: inout [PendingError],
        enqueuedNSErrorIDs: inout Set<ObjectIdentifier>,
        traversalWasTruncated: inout Bool
    ) -> Bool {
        let candidate = PendingError(error)
        guard !enqueuedNSErrorIDs.contains(candidate.identity) else {
            return true
        }
        guard pending.count < maximumTraversalNodeCount else {
            traversalWasTruncated = true
            return false
        }

        enqueuedNSErrorIDs.insert(candidate.identity)
        pending.append(candidate)
        return true
    }

    private static func classifyDirect(
        _ error: Error,
        nsError: NSError
    ) -> LocalSummaryTelemetryErrorClassification? {
        if error is CancellationError {
            return .cancelled(stage: .generate)
        }
        if let localSummaryError = error as? LocalMeetingSummaryError {
            return classify(localSummaryError)
        }
        if error is DecodingError || error is EncodingError {
            return .failure(kind: .invalidOutput, stage: .generate)
        }
        return classify(nsError)
    }

    private static func precedence(
        of classification: LocalSummaryTelemetryErrorClassification
    ) -> Int {
        switch classification {
        case .cancelled:
            return 3
        case .failure(let kind, _):
            switch kind {
            case .unknown:
                return 0
            case .ioError:
                return 1
            default:
                return 2
            }
        }
    }

    private static func classify(
        _ error: LocalMeetingSummaryError
    ) -> LocalSummaryTelemetryErrorClassification {
        switch error {
        case .emptyTranscript:
            return .failure(kind: .emptyTranscript, stage: .input)
        case .insufficientMemory:
            return .failure(kind: .insufficientMemory, stage: .setup)
        case .runtimeUnavailable:
            return .failure(kind: .runtimeUnavailable, stage: .setup)
        case .appleFoundationUnavailable:
            return .failure(kind: .appleFoundationUnavailable, stage: .setup)
        case .missingBundledRunner:
            return .failure(kind: .missingRunner, stage: .setup)
        case .transcriptChanged:
            return .failure(kind: .transcriptChanged, stage: .write)
        case .processTimedOut:
            return .failure(kind: .timeout, stage: .generate)
        case .processFailed:
            return .failure(kind: .processFailed, stage: .generate)
        case .outputMissing:
            return .failure(kind: .outputMissing, stage: .generate)
        }
    }

    private static func classify(
        _ error: NSError
    ) -> LocalSummaryTelemetryErrorClassification? {
        switch error.domain {
        case NSCocoaErrorDomain:
            switch error.code {
            case 4, 260:
                return .failure(kind: .fileNotFound, stage: .fileIO)
            case 257, 513:
                return .failure(kind: .permissionDenied, stage: .fileIO)
            case 640:
                return .failure(kind: .diskFull, stage: .write)
            case 256...264, 512...518, 641...642:
                return .failure(kind: .ioError, stage: .fileIO)
            case 3584...3587:
                return .failure(kind: .runtimeUnavailable, stage: .setup)
            default:
                return nil
            }
        case NSPOSIXErrorDomain:
            switch POSIXErrorCode(rawValue: Int32(error.code)) {
            case .ENOENT:
                return .failure(kind: .fileNotFound, stage: .fileIO)
            case .EACCES, .EPERM:
                return .failure(kind: .permissionDenied, stage: .fileIO)
            case .ENOSPC:
                return .failure(kind: .diskFull, stage: .write)
            case .ETIMEDOUT:
                return .failure(kind: .timeout, stage: .generate)
            case .ECANCELED:
                return .cancelled(stage: .generate)
            case .ENOEXEC:
                return .failure(kind: .runtimeUnavailable, stage: .setup)
            case .ENOMEM:
                return .failure(kind: .insufficientMemory, stage: .setup)
            case .EIO:
                return .failure(kind: .ioError, stage: .fileIO)
            default:
                return nil
            }
        case NSURLErrorDomain:
            switch error.code {
            case NSURLErrorCancelled:
                return .cancelled(stage: .setup)
            case NSURLErrorTimedOut:
                return .failure(kind: .timeout, stage: .setup)
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotLoadFromNetwork:
                return .failure(kind: .networkUnavailable, stage: .setup)
            default:
                return nil
            }
        default:
            return nil
        }
    }
}

import Foundation

public enum RecordingStopFinalizationDisposition: Sendable, Equatable {
    case finalized
    case journalRecoveryOwned
}

/// Keep independent audio backends independent during shutdown. Each writer
/// closes only after its producer stops and its serial queue drains. Completion
/// also waits for any host-buffer drain already registered in `group`.
enum AudioStopCleanup {
    static func schedule(
        group: DispatchGroup,
        microphoneFileQueue: DispatchQueue,
        systemFileQueue: DispatchQueue,
        stopMicrophone: @escaping () -> Void,
        stopSystem: @escaping () -> Void,
        closeMicrophone: @escaping () -> Void,
        closeSystem: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        // Register both branches before dispatch or notify: either branch can
        // finish immediately, including when recording never finished starting.
        group.enter()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stopMicrophone()
            microphoneFileQueue.async {
                closeMicrophone()
                group.leave()
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            stopSystem()
            systemFileQueue.async {
                closeSystem()
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .utility), execute: completion)
    }
}

// Plain recording ownership values. Mutable context/ticket fields are accessed
// only by RecordingArtifactOwnership while its state lock is held.
enum TerminalDecision: Equatable { case undecided, discard, recovery }
enum DiscardAdmission: Equatable { case selected, alreadySelected, rejectedRecoveryOwner, notOwned }
enum AbandonAdmission: Equatable { case selected, alreadySelected, rejectedDiscardOwner, finalizerOwned, notOwned }
enum DiscardMode: Equatable { case pendingClaimHeld, afterNormalReleaseCompatibility }
enum ArtifactRole: Equatable { case initial, recovery }
enum MicArtifactRetirement: Equatable { case retired, alreadyRetired }
enum CleanupResult: Equatable { case removed, retainedAfterCleanupFailure }
enum StopSystemOutcome: Equatable { case unresolved, handedOff(URL?) }

struct RecordingArtifactJournalBinding<E: AnyObject, T: Equatable>: @unchecked Sendable {
    let endpoint: E
    let token: T
}

struct RecordingArtifactInventory: Equatable {
    let primaryURL: URL?
    let segments: [MicRecordingSegment]
    let finalMicURL: URL?
    let finalSystemURL: URL?
    let allowedRoot: URL
    let journalURL: URL?
    let journalData: Data?

    init(primaryURL: URL? = nil, segments: [MicRecordingSegment] = [],
         finalMicURL: URL? = nil, finalSystemURL: URL? = nil,
         allowedRoot: URL, journalURL: URL? = nil, journalData: Data? = nil) {
        self.primaryURL = primaryURL
        self.segments = segments
        self.finalMicURL = finalMicURL
        self.finalSystemURL = finalSystemURL
        self.allowedRoot = allowedRoot
        self.journalURL = journalURL
        self.journalData = journalData
    }

    var audioURLs: [URL] {
        ([primaryURL, finalMicURL, finalSystemURL] + segments.map { Optional($0.url) }).compactMap { $0 }
    }
}

final class RecordingArtifactContext<F, E: AnyObject, T: Equatable>: @unchecked Sendable {
    let captureGeneration: UInt64
    let ownerIdentity: ObjectIdentifier
    let facts: F
    let endpoint: E
    let allowedRoot: URL
    var primaryURL: URL?
    var segments: [MicRecordingSegment] = []
    var systemCandidate: URL?
    var stopSystem: StopSystemOutcome = .unresolved
    var token: T?
    var decision: TerminalDecision = .undecided
    var sealed = false
    var initialAdmitted = false
    var initialCompleted = false
    weak var stopTicket: RecordingArtifactStopTicket<F,E,T>?
    var nextAttempt: UInt64 = 0
    var settledAttempts: Set<UInt64> = []
    var registeredAttempts: Set<UInt64> = []

    init(captureGeneration: UInt64, ownerIdentity: ObjectIdentifier, facts: F, endpoint: E, allowedRoot: URL) {
        self.captureGeneration = captureGeneration
        self.ownerIdentity = ownerIdentity
        self.facts = facts
        self.endpoint = endpoint
        self.allowedRoot = allowedRoot
    }
}

final class RecordingArtifactStopTicket<F, E: AnyObject, T: Equatable>: @unchecked Sendable {
    let context: RecordingArtifactContext<F,E,T>
    let stopGeneration: UInt64
    var quiescent = false
    var finalizerClaimed = false
    var normalReleaseCommitted = false
    var normalReleaseEnqueued = false
    var normalCompleted = false
    var actualFinalMicURL: URL?
    var cleanupClaimed = false
    var completionScheduled = false
    var terminalFinished = false

    init(context: RecordingArtifactContext<F,E,T>, stopGeneration: UInt64) {
        self.context = context
        self.stopGeneration = stopGeneration
    }
}

struct RecordingArtifactSnapshot<E: AnyObject, T: Equatable>: @unchecked Sendable {
    let captureGeneration: UInt64
    let stopGeneration: UInt64
    let primaryURL: URL?
    let segments: [MicRecordingSegment]
    let finalSystemURL: URL?
    let binding: RecordingArtifactJournalBinding<E,T>?
    let terminalDecision: TerminalDecision
    let allowedRoot: URL

    func inventory(finalMicURL: URL?, journalURL: URL? = nil) -> RecordingArtifactInventory {
        RecordingArtifactInventory(primaryURL: primaryURL, segments: segments,
            finalMicURL: finalMicURL, finalSystemURL: finalSystemURL,
            allowedRoot: allowedRoot, journalURL: journalURL)
    }
}

struct RecoveryAttemptIdentity: Hashable { let generation: UInt64; let sequence: UInt64 }

final class RecordingArtifactRecoveryAttempt<W: AnyObject>: @unchecked Sendable {
    let identity: RecoveryAttemptIdentity
    let context: AnyObject
    let url: URL
    let writer: W
    init(identity: RecoveryAttemptIdentity, context: AnyObject, url: URL, writer: W) {
        self.identity = identity; self.context = context; self.url = url; self.writer = writer
    }
}

enum InitialSetupResult<C> { case started(C), stale }
enum RecoverySetupResult<W: AnyObject,C> {
    case registered(RecordingArtifactRecoveryAttempt<W>, C), notOwned
}
enum RecoveryFinishResult: Equatable { case kept, removed, stopOwnsRegisteredSegment, alreadySettled }
enum QuiescentClaim<E: AnyObject,T: Equatable> {
    case normal(RecordingArtifactSnapshot<E,T>)
    case normalThenDiscard(RecordingArtifactSnapshot<E,T>)
    case recovery(RecordingArtifactSnapshot<E,T>)
    case notOwned
}

struct FinalizationOutput: Equatable, Sendable {
    let stopGeneration: UInt64
    let micURL: URL?
    let systemURL: URL?
    let disposition: RecordingStopFinalizationDisposition
}

enum CompletionDelivery: Sendable { case stopOnce(FinalizationOutput), noneAlreadyScheduled }
enum RecordingArtifactTerminalAction<E: AnyObject,T: Equatable>: @unchecked Sendable {
    case normalRelease(RecordingArtifactSnapshot<E,T>, FinalizationOutput)
    case discard(RecordingArtifactSnapshot<E,T>, RecordingArtifactInventory, DiscardMode)
    case recoveryRelease(RecordingArtifactSnapshot<E,T>)
    case complete(CompletionDelivery)
    case waitForExistingNormalFinalizer
    case noAction
}

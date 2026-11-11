import Foundation
import XCTest
@testable import TranscriptedCore

// Written from the frozen CORE12 API v5 before reading its implementation.
// These fakes perform individual effects only. Production owns all dispatch,
// writer ownership, transaction sequencing and terminal decisions.
struct ArtifactTestFacts: Equatable, Sendable {
    let language: String
    let micOnly: Bool
}

final class ArtifactTestWriter: @unchecked Sendable {
    let url: URL
    init(_ url: URL) { self.url = url }
}

final class ArtifactTestEndpoint: @unchecked Sendable {
    let id: Int
    var inventory: RecordingArtifactInventory?
    var liveClaim = false
    init(_ id: Int) { self.id = id }
}

final class ArtifactTestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var cleanupValues: [RecordingArtifactInventory] = []
    private var delivered: [FinalizationOutput] = []

    func append(_ value: String) {
        lock.lock(); events.append(value); lock.unlock()
    }
    var values: [String] {
        lock.lock(); defer { lock.unlock() }; return events
    }
    func cleanup(_ inventory: RecordingArtifactInventory) {
        lock.lock(); cleanupValues.append(inventory); lock.unlock()
    }
    var cleanups: [RecordingArtifactInventory] {
        lock.lock(); defer { lock.unlock() }; return cleanupValues
    }
    func output(_ value: FinalizationOutput) {
        lock.lock(); delivered.append(value); lock.unlock()
    }
    var outputs: [FinalizationOutput] {
        lock.lock(); defer { lock.unlock() }; return delivered
    }
}

// A checkpoint controls fake effects, never production time. XCTest timeout
// arguments elsewhere are deadlock watchdogs, not elapsed-time assertions.
final class ArtifactTestGate: @unchecked Sendable {
    let entered: XCTestExpectation
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var used = false
    init(_ name: String) { entered = XCTestExpectation(description: name) }
    func pause() {
        lock.lock()
        guard !used else { lock.unlock(); return }
        used = true
        lock.unlock()
        entered.fulfill()
        release.wait()
    }
    func open() { release.signal() }
}

enum ArtifactTestError: Error { case begin, create }

final class ArtifactTestEffects: @unchecked Sendable {
    let log = ArtifactTestLog()
    let allowedRoot = URL(fileURLWithPath: "/synthetic", isDirectory: true)
    let root = URL(fileURLWithPath: "/synthetic/core12", isDirectory: true)
    var onBegin: (() -> Void)?
    var onCreate: (() -> Void)?
    var onClose: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCleanup: (() -> Void)?
    var onMerge: (() -> Void)?
    var onFinalized: ((Bool) -> Void)?
    var throwBegin = false
    var throwCreate = false
    var cleanupSucceeds = true
    var snapshotMissing = false
    var initialJournalURL: URL?
    var initialJournalData: Data?
    var nextFile = 0 // Written only on the injected mic queue.
}

typealias ArtifactTestOwner = RecordingArtifactOwnership<ArtifactTestFacts, ArtifactTestEndpoint, Int>
typealias ArtifactTestContext = RecordingArtifactContext<ArtifactTestFacts, ArtifactTestEndpoint, Int>
typealias ArtifactTestTicket = RecordingArtifactStopTicket<ArtifactTestFacts, ArtifactTestEndpoint, Int>
typealias ArtifactTestSnapshot = RecordingArtifactSnapshot<ArtifactTestEndpoint, Int>

final class ArtifactTestFixture: @unchecked Sendable {
    let effects = ArtifactTestEffects()
    let clock = RecordingGenerationClock()
    let writer = MicWriterOwnership<ArtifactTestWriter>()
    let mic = DispatchQueue(label: "test.core12.mic")
    let system = DispatchQueue(label: "test.core12.system")
    let journalQueue = DispatchQueue(label: "test.core12.journal")
    let work = DispatchQueue(label: "test.core12.work")
    let callbacks = DispatchQueue(label: "test.core12.callbacks")
    let dispatcher: JournalCommandDispatcher<ArtifactTestFacts, ArtifactTestEndpoint, Int>
    let owner: ArtifactTestOwner
    let transactions: MicArtifactTransactions<ArtifactTestWriter, Int, ArtifactTestFacts, ArtifactTestEndpoint, Int>
    let completion: RecordingArtifactCompletion<ArtifactTestFacts, ArtifactTestEndpoint, Int>

    init() {
        let effects = effects
        let writer = writer
        let journalQueue = journalQueue
        dispatcher = JournalCommandDispatcher(queue: journalQueue, applications: JournalApplications(
            recordSegments: { binding, segments in
                guard binding.token == binding.endpoint.id else { return }
                effects.log.append("segments:\(binding.endpoint.id)")
                if let old = binding.endpoint.inventory {
                    binding.endpoint.inventory = RecordingArtifactInventory(
                        primaryURL: old.primaryURL, segments: segments,
                        finalMicURL: old.finalMicURL, finalSystemURL: old.finalSystemURL,
                        allowedRoot: old.allowedRoot, journalURL: old.journalURL, journalData: old.journalData
                    )
                }
            },
            recordSystemURL: { binding, url in
                guard binding.token == binding.endpoint.id else { return }
                effects.log.append("system:\(binding.endpoint.id)")
                if let old = binding.endpoint.inventory {
                    binding.endpoint.inventory = RecordingArtifactInventory(
                        primaryURL: old.primaryURL, segments: old.segments,
                        finalMicURL: old.finalMicURL, finalSystemURL: url,
                        allowedRoot: old.allowedRoot, journalURL: old.journalURL, journalData: old.journalData
                    )
                }
            },
            clearSystemURL: { binding in
                guard binding.token == binding.endpoint.id else { return }
                effects.log.append("clear-system:\(binding.endpoint.id)")
                if let old = binding.endpoint.inventory {
                    binding.endpoint.inventory = RecordingArtifactInventory(
                        primaryURL: old.primaryURL, segments: old.segments,
                        finalMicURL: old.finalMicURL, finalSystemURL: nil,
                        allowedRoot: old.allowedRoot, journalURL: old.journalURL, journalData: old.journalData
                    )
                }
            },
            markStopping: { binding in
                guard binding.token == binding.endpoint.id else { return }
                effects.log.append("stopping:\(binding.endpoint.id)")
            },
            markFinalized: { binding, url, endingSession in
                guard binding.token == binding.endpoint.id else { return }
                effects.log.append("finalized:\(binding.endpoint.id):\(endingSession)")
                if let old = binding.endpoint.inventory {
                    binding.endpoint.inventory = RecordingArtifactInventory(
                        primaryURL: old.primaryURL, segments: old.segments,
                        finalMicURL: url, finalSystemURL: old.finalSystemURL,
                        allowedRoot: old.allowedRoot, journalURL: old.journalURL, journalData: old.journalData
                    )
                }
                if endingSession { binding.endpoint.liveClaim = false }
                effects.onFinalized?(endingSession)
            },
            snapshotOwnedDiscard: { binding in
                guard binding.token == binding.endpoint.id else { return nil }
                effects.log.append("snapshot:\(binding.endpoint.id)")
                return effects.snapshotMissing ? nil : binding.endpoint.inventory
            },
            finishOwnedDiscard: { binding, succeeded in
                guard binding.token == binding.endpoint.id else { return }
                effects.log.append("discard-release:\(binding.endpoint.id):\(succeeded)")
                binding.endpoint.inventory = nil
                binding.endpoint.liveClaim = false
            },
            releaseRecovery: { binding in
                guard binding.token == binding.endpoint.id else { return }
                effects.log.append("release-enter:\(binding.endpoint.id)")
                effects.onRelease?()
                binding.endpoint.liveClaim = false
                effects.log.append("release-done:\(binding.endpoint.id)")
            }
        ))
        owner = ArtifactTestOwner(clock: clock, journalCommands: dispatcher, allowedRoot: effects.allowedRoot)
        transactions = MicArtifactTransactions(
            queue: mic, writerOwnership: writer, owner: owner,
            files: FileActions(
                allocateURL: { _ in
                    effects.nextFile += 1
                    let url = effects.root.appendingPathComponent("artifact-\(effects.nextFile).wav")
                    effects.log.append("allocate:\(url.lastPathComponent)")
                    return url
                },
                createWriter: { url, _ in
                    effects.log.append("create:\(url.lastPathComponent)")
                    effects.onCreate?()
                    if effects.throwCreate { throw ArtifactTestError.create }
                    return ArtifactTestWriter(url)
                },
                closeWriter: { file in
                    effects.log.append("close-enter:\(file.url.lastPathComponent)")
                    effects.onClose?()
                    effects.log.append("close-done:\(file.url.lastPathComponent)")
                },
                restrictPermissions: { url in effects.log.append("permissions:\(url.lastPathComponent)") },
                removeFile: { url in effects.log.append("remove:\(url.lastPathComponent)") }
            ),
            journal: JournalBegin(begin: { endpoint, url, facts in
                try journalQueue.sync {
                    effects.log.append("begin:\(endpoint.id):\(facts.language):\(facts.micOnly)")
                    // Observe the real production writer slot at the begin edge.
                    effects.log.append("installed-at-begin:\(writer.writer?.url == url)")
                    effects.onBegin?()
                    if effects.throwBegin { throw ArtifactTestError.begin }
                    endpoint.inventory = RecordingArtifactInventory(
                        primaryURL: url, segments: [MicRecordingSegment(url: url)], allowedRoot: effects.allowedRoot,
                        journalURL: effects.initialJournalURL, journalData: effects.initialJournalData
                    )
                    endpoint.liveClaim = true
                    return endpoint.id
                }
            })
        )
        completion = RecordingArtifactCompletion(
            owner: owner, journal: dispatcher,
            files: TerminalFileActions(
                merge: { snapshot in
                    effects.log.append("merge:\(snapshot.stopGeneration)")
                    effects.onMerge?()
                    return snapshot.primaryURL?.appendingPathExtension("merged")
                },
                safeCleanup: { inventory in
                    effects.log.cleanup(inventory)
                    effects.log.append("cleanup:\(inventory.finalMicURL?.lastPathComponent ?? "nil")")
                    effects.onCleanup?()
                    return effects.cleanupSucceeds
                }
            ), workQueue: work, callbackQueue: callbacks
        )
    }

    func context(_ id: Int = 1, language: String = "a", micOnly: Bool = false) -> ArtifactTestContext {
        owner.beginContext(facts: ArtifactTestFacts(language: language, micOnly: micOnly), endpoint: ArtifactTestEndpoint(id))
    }

    func start(_ context: ArtifactTestContext) throws {
        guard case .started = try transactions.createInitial(context: context, prepared: 48_000) else {
            return XCTFail("current initial transaction should start")
        }
    }

    func seal(_ context: ArtifactTestContext, systemURL: URL? = nil) throws -> ArtifactTestTicket {
        let ticket = try XCTUnwrap(owner.sealStop(expectedCaptureGeneration: context.captureGeneration))
        owner.commitStopSystemHandoff(ticket, url: systemURL)
        return ticket
    }

    func close(_ ticket: ArtifactTestTicket) -> ArtifactTestSnapshot {
        mic.sync { transactions.closeForStopOnQueue(ticket: ticket) }
    }

    func edges(_ label: String, done: XCTestExpectation) -> CompletionEdges {
        let log = effects.log
        return CompletionEdges(
            beforeDelivery: { value in log.output(value); log.append("before:\(label)") },
            timeline: { _ in log.append("timeline:\(label)") },
            generation: { _ in log.append("generation:\(label)") },
            legacy: { _, _ in log.append("legacy:\(label)"); done.fulfill() }
        )
    }

    func schedule(_ ticket: ArtifactTestTicket, done: XCTestExpectation,
                  group: DispatchGroup = DispatchGroup(), stopMic: @escaping () -> Void = {},
                  stopSystem: @escaping () -> Void = {}, closeSystem: @escaping () -> Void = {},
                  label: String = "a") {
        AudioStopCleanup.schedule(
            group: group, microphoneFileQueue: mic, systemFileQueue: system,
            stopMicrophone: stopMic, stopSystem: stopSystem,
            closeMicrophone: { _ = self.transactions.closeForStopOnQueue(ticket: ticket) },
            closeSystem: closeSystem,
            completion: { self.completion.afterOwnedArtifactsDrained(ticket, callbacks: self.edges(label, done: done)) }
        )
    }

    func flushJournal() { journalQueue.sync {} }
}

final class ArtifactTestResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Value, Error>?
    func set(_ value: Result<Value, Error>) {
        lock.lock(); storage = value; lock.unlock()
    }
    func get() throws -> Value {
        lock.lock(); let value = storage; lock.unlock()
        return try XCTUnwrap(value).get()
    }
}

func assertArtifactOrder(_ expected: [String], in actual: [String],
                         file: StaticString = #filePath, line: UInt = #line) {
    var cursor = actual.startIndex
    for event in expected {
        guard let index = actual[cursor...].firstIndex(of: event) else {
            XCTFail("Missing ordered effect \(event); got \(actual)", file: file, line: line)
            return
        }
        cursor = actual.index(after: index)
    }
}

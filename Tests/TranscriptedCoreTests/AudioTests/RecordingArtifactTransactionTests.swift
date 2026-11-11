import Foundation
import XCTest
@testable import TranscriptedCore

final class RecordingArtifactTransactionTests: XCTestCase {
    func testAdmittedInitialBeginCannotBePassedByStopOrSuccessorSetup() async throws {
        let f = ArtifactTestFixture()
        let a = f.context(1, language: "language-a", micOnly: true)
        let gate = ArtifactTestGate("initial begin entered")
        f.effects.onBegin = { gate.pause() }
        defer { gate.open() }
        let initialDone = expectation(description: "initial transaction returned")
        let aResult = ArtifactTestResult<Void>()
        DispatchQueue.global().async {
            aResult.set(Result { try f.start(a) })
            initialDone.fulfill()
        }
        await fulfillment(of: [gate.entered], timeout: 20)
        let systemA = f.effects.root.appendingPathComponent("system-a.wav")
        let stop = try f.seal(a, systemURL: systemA)
        let stopDone = expectation(description: "Stop completed")
        let systemClosed = expectation(description: "independent system writer closed")
        f.schedule(stop, done: stopDone, closeSystem: { systemClosed.fulfill() })
        let b = f.context(2, language: "language-b", micOnly: false)
        let bResult = ArtifactTestResult<Void>()
        let successorDone = expectation(description: "successor transaction returned")
        DispatchQueue.global().async {
            bResult.set(Result { try f.start(b) })
            successorDone.fulfill()
        }
        await fulfillment(of: [systemClosed], timeout: 20)
        XCTAssertFalse(f.effects.log.values.contains("before:a"), "Stop cannot complete through an admitted begin")
        XCTAssertFalse(f.effects.log.values.contains("begin:2:language-b:false"), "B cannot pass A on the same queue")
        gate.open()
        await fulfillment(of: [initialDone, successorDone, stopDone], timeout: 20)
        try aResult.get(); try bResult.get()
        f.flushJournal()
        XCTAssertEqual(a.endpoint.inventory?.finalSystemURL, systemA)
        XCTAssertEqual(a.facts, ArtifactTestFacts(language: "language-a", micOnly: true))
        XCTAssertEqual(b.facts, ArtifactTestFacts(language: "language-b", micOnly: false))
        XCTAssertTrue(f.writer.writerOwned(by: b.captureGeneration) != nil, "A Stop cannot detach B writer")
        assertArtifactOrder(["installed-at-begin:true", "begin:2:language-b:false"], in: f.effects.log.values)
    }

    func testNilHandoffBeforeLateInitialTokenNeverResurrectsCandidateOrTouchesB() async throws {
        let f = ArtifactTestFixture()
        let a = f.context(1)
        let candidate = f.effects.root.appendingPathComponent("candidate-a.wav")
        XCTAssertTrue(f.owner.bindSystemCandidate(a, url: candidate))
        let gate = ArtifactTestGate("initial token pending")
        f.effects.onBegin = { gate.pause() }
        defer { gate.open() }
        let returned = expectation(description: "late initial returned")
        let result = ArtifactTestResult<Void>()
        DispatchQueue.global().async { result.set(Result { try f.start(a) }); returned.fulfill() }
        await fulfillment(of: [gate.entered], timeout: 20)
        let stop = try f.seal(a, systemURL: nil)
        let b = f.context(2)
        let systemB = f.effects.root.appendingPathComponent("system-b.wav")
        XCTAssertTrue(f.owner.bindSystemCandidate(b, url: systemB))
        gate.open()
        await fulfillment(of: [returned], timeout: 20)
        try result.get()
        let snapshot = f.close(stop)
        f.flushJournal()
        XCTAssertNil(snapshot.finalSystemURL)
        XCTAssertNil(a.endpoint.inventory?.finalSystemURL)
        XCTAssertFalse(f.effects.log.values.contains("system:1"), "old candidate cannot be journaled after authoritative nil")
        XCTAssertNil(b.endpoint.inventory, "A late begin must not create B journal")
        try f.start(b)
        f.flushJournal()
        XCTAssertEqual(b.endpoint.inventory?.finalSystemURL, systemB)
    }

    func testBeginFailureRollsBackItsExactInstalledFileBeforeStopCanClose() throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        f.effects.throwBegin = true
        XCTAssertThrowsError(try f.start(a))
        let stop = try f.seal(a)
        let snapshot = f.close(stop)
        XCTAssertNil(f.writer.writerOwned(by: a.captureGeneration))
        XCTAssertNil(snapshot.binding)
        XCTAssertNil(snapshot.primaryURL)
        assertArtifactOrder([
            "create:artifact-1.wav", "installed-at-begin:true",
            "close-done:artifact-1.wav", "remove:artifact-1.wav"
        ], in: f.effects.log.values)
        XCTAssertEqual(f.effects.log.values.filter { $0 == "close-done:artifact-1.wav" }.count, 1)
    }

    func testHeldRetiringExplicitClosePreventsStopFinalizationAndUnregisteredPartialEscapes() async throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        let retainedOriginal = try XCTUnwrap(f.writer.writerOwned(by: a.captureGeneration))
        let gate = ArtifactTestGate("retired explicit close")
        f.effects.onClose = { gate.pause() }
        defer { gate.open() }
        let recoveryReturned = expectation(description: "recovery transaction settled")
        let result = ArtifactTestResult<Void>()
        DispatchQueue.global().async {
            result.set(Result {
                guard case .notOwned = try f.transactions.createRecovery(context: a, prepared: 44_100, gapBefore: 2) else {
                    return XCTFail("registration that loses Stop must return no registered attempt")
                }
            })
            recoveryReturned.fulfill()
        }
        await fulfillment(of: [gate.entered], timeout: 20)
        XCTAssertNil(f.writer.writerOwned(by: a.captureGeneration))
        let stop = try f.seal(a)
        let stopDone = expectation(description: "Stop after retirement rollback")
        let systemClosed = expectation(description: "system independent of retirement")
        f.schedule(stop, done: stopDone, closeSystem: { systemClosed.fulfill() })
        await fulfillment(of: [systemClosed], timeout: 20)
        XCTAssertFalse(f.effects.log.values.contains("before:a"))
        gate.open()
        await fulfillment(of: [recoveryReturned, stopDone], timeout: 20)
        try result.get()
        f.flushJournal()
        XCTAssertEqual(retainedOriginal.url.lastPathComponent, "artifact-1.wav", "a strong reference survives explicit close")
        XCTAssertEqual(a.endpoint.inventory?.segments.map(\.url.lastPathComponent), ["artifact-1.wav"])
        assertArtifactOrder([
            "close-done:artifact-1.wav", "create:artifact-2.wav",
            "close-done:artifact-2.wav", "remove:artifact-2.wav", "before:a"
        ], in: f.effects.log.values)
    }

    func testRegisteredRecoveryIsKeptWhenStopWinsItsDeferredUnregister() throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        guard case .registered(let attempt, _) = try f.transactions.createRecovery(context: a, prepared: 44_100, gapBefore: 3) else {
            return XCTFail("current recovery should register")
        }
        let stop = try f.seal(a)
        f.flushJournal()
        let before = f.effects.log.values
        guard case .stopOwnsRegisteredSegment = try f.transactions.finishRecovery(attempt: attempt, keep: false) else {
            return XCTFail("registered segment belongs to Stop after its cutoff")
        }
        XCTAssertEqual(f.effects.log.values, before, "late deferred cleanup must not close or unlink Stop's segment")
        let snapshot = f.close(stop)
        XCTAssertEqual(snapshot.segments.map(\.url.lastPathComponent), ["artifact-1.wav", "artifact-2.wav"])
        XCTAssertEqual(snapshot.segments.last?.gapBeforeDuration, 3)
        XCTAssertFalse(f.effects.log.values.contains("remove:artifact-2.wav"))
    }

    func testUnregisterWinningBeforeStopRemovesOnlyItsOwnSegmentOnce() throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        guard case .registered(let attempt, _) = try f.transactions.createRecovery(context: a, prepared: 44_100, gapBefore: 3) else {
            return XCTFail("recovery should register")
        }
        guard case .removed = try f.transactions.finishRecovery(attempt: attempt, keep: false) else { return XCTFail("owned failed attempt should roll back") }
        guard case .alreadySettled = try f.transactions.finishRecovery(attempt: attempt, keep: false) else { return XCTFail("duplicate finish must do nothing") }
        let stop = try f.seal(a)
        let snapshot = f.close(stop)
        f.flushJournal()
        XCTAssertEqual(snapshot.segments.map(\.url.lastPathComponent), ["artifact-1.wav"])
        XCTAssertEqual(f.effects.log.values.filter { $0 == "remove:artifact-2.wav" }.count, 1)
        assertArtifactOrder(["close-done:artifact-2.wav", "remove:artifact-2.wav", "stopping:1"], in: f.effects.log.values)
    }

    func testRecoveryGapUpdateIsGenerationBoundAndKeepsTheOrderedInventory() throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        guard case .registered = try f.transactions.createRecovery(context: a, prepared: 44_100, gapBefore: 2) else { return XCTFail("recovery should register") }
        let recoveryURL = f.effects.root.appendingPathComponent("artifact-2.wav")
        XCTAssertTrue(f.owner.updateGap(a, url: recoveryURL, gapBefore: 4))
        let stop = try f.seal(a)
        XCTAssertFalse(f.owner.updateGap(a, url: recoveryURL, gapBefore: 99))
        let snapshot = f.close(stop)
        XCTAssertEqual(snapshot.segments.map(\.gapBeforeDuration), [0, 4])
    }

    func testRejectedStaleRecoveryCannotRetireCreateOrDeleteSuccessorWriter() throws {
        let f = ArtifactTestFixture()
        let a = f.context(1)
        try f.start(a)
        let stop = try f.seal(a)
        _ = f.close(stop)
        let b = f.context(2)
        try f.start(b)
        f.flushJournal()
        let successor = try XCTUnwrap(f.writer.writerOwned(by: b.captureGeneration))
        let before = f.effects.log.values
        guard case .notOwned = try f.transactions.createRecovery(context: a, prepared: 44_100, gapBefore: 3) else {
            return XCTFail("sealed A cannot retire or replace B's writer")
        }
        XCTAssertTrue(f.writer.writerOwned(by: b.captureGeneration) === successor)
        XCTAssertEqual(f.effects.log.values, before)
    }

    func testKeptRecoveryFinishesOnceWithoutUnlinkingItsRegisteredSegment() throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        guard case .registered(let attempt, _) = try f.transactions.createRecovery(context: a, prepared: 44_100, gapBefore: 3) else {
            return XCTFail("recovery should register")
        }
        guard case .kept = try f.transactions.finishRecovery(attempt: attempt, keep: true) else { return XCTFail("successful recovery should keep segment") }
        guard case .alreadySettled = try f.transactions.finishRecovery(attempt: attempt, keep: false) else { return XCTFail("a duplicate cannot reverse keep") }
        let snapshot = f.close(try f.seal(a))
        XCTAssertEqual(snapshot.segments.map(\.url.lastPathComponent), ["artifact-1.wav", "artifact-2.wav"])
        XCTAssertFalse(f.effects.log.values.contains("remove:artifact-2.wav"))
    }

    func testRecoveryCanRetryAfterCreationFailureLeftItsWriterAlreadyRetired() throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        f.effects.throwCreate = true
        XCTAssertThrowsError(try f.transactions.createRecovery(context: a, prepared: 44_100, gapBefore: 2))
        XCTAssertNil(f.writer.writerOwned(by: a.captureGeneration))
        XCTAssertEqual(f.effects.log.values.filter { $0 == "remove:artifact-2.wav" }.count, 1,
                       "failed creation must settle the allocated unregistered artifact before retry")
        f.effects.throwCreate = false
        guard case .registered(let attempt, _) = try f.transactions.createRecovery(context: a, prepared: 48_000, gapBefore: 4) else {
            return XCTFail("already-retired same-generation writer must permit the next attempt")
        }
        guard case .kept = try f.transactions.finishRecovery(attempt: attempt, keep: true) else { return XCTFail("retry should be kept") }
        let snapshot = f.close(try f.seal(a))
        XCTAssertEqual(snapshot.segments.map(\.url.lastPathComponent), ["artifact-1.wav", "artifact-3.wav"])
        XCTAssertEqual(f.effects.log.values.filter { $0 == "close-done:artifact-1.wav" }.count, 1)
        XCTAssertTrue(f.writer.recordingOwnsMicFile(a.captureGeneration) == false)
    }

    func testRemakeBeforeCloseUsesSameURLAndAfterCloseCannotResurrectWriter() throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        let originalURL = try XCTUnwrap(f.writer.writerOwned(by: a.captureGeneration)).url
        guard case .started = try f.transactions.remakeInitial(context: a, prepared: 24_000) else { return XCTFail("live remake should replace empty writer") }
        XCTAssertEqual(f.writer.writerOwned(by: a.captureGeneration)?.url, originalURL)
        let stop = try f.seal(a)
        _ = f.close(stop)
        let before = f.effects.log.values
        guard case .stale = try f.transactions.remakeInitial(context: a, prepared: 48_000) else { return XCTFail("closed remake must be stale") }
        XCTAssertNil(f.writer.writerOwned(by: a.captureGeneration))
        XCTAssertEqual(f.effects.log.values, before)
    }

    func testGapExpressionRunsOnceAfterInstallAndIsNotEvaluatedForRejectedOrFailedSetup() throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        f.flushJournal()
        let before = f.effects.log.values.count
        var evaluations = 0
        func gapValue() -> TimeInterval {
            evaluations += 1
            f.effects.log.append("gap-expression")
            XCTAssertEqual(f.writer.writerOwned(by: a.captureGeneration)?.url.lastPathComponent, "artifact-2.wav")
            // These acquire the actual G/O locks. The gap expression belongs
            // outside both, after installation and before registration.
            XCTAssertNotEqual(f.clock.predictedNext(), f.clock.current)
            XCTAssertTrue(f.owner.currentContext() === a)
            return 7.25
        }
        guard case .registered(let attempt, _) = try f.transactions.createRecovery(context: a, prepared: 44_100, gapBefore: gapValue()) else {
            return XCTFail("current recovery should register the lazily evaluated gap")
        }
        f.flushJournal()
        XCTAssertEqual(evaluations, 1)
        assertArtifactOrder([
            "close-done:artifact-1.wav", "create:artifact-2.wav", "permissions:artifact-2.wav",
            "gap-expression", "segments:1"
        ], in: Array(f.effects.log.values.dropFirst(before)))
        guard case .kept = try f.transactions.finishRecovery(attempt: attempt, keep: true) else { return XCTFail("recovery should keep its evaluated gap") }
        XCTAssertEqual(f.close(try f.seal(a)).segments.map(\.gapBeforeDuration), [0, 7.25])

        let rejected = ArtifactTestFixture()
        let stale = rejected.context()
        _ = try rejected.seal(stale)
        var rejectedEvaluations = 0
        func rejectedGap() -> TimeInterval { rejectedEvaluations += 1; return 99 }
        guard case .notOwned = try rejected.transactions.createRecovery(context: stale, prepared: 48_000, gapBefore: rejectedGap()) else {
            return XCTFail("pre-admission rejection must not evaluate the gap")
        }
        XCTAssertEqual(rejectedEvaluations, 0)

        let failed = ArtifactTestFixture()
        let current = failed.context()
        try failed.start(current)
        failed.effects.throwCreate = true
        var failedEvaluations = 0
        func failedGap() -> TimeInterval { failedEvaluations += 1; return 99 }
        XCTAssertThrowsError(try failed.transactions.createRecovery(context: current, prepared: 48_000, gapBefore: failedGap()))
        XCTAssertEqual(failedEvaluations, 0, "file creation failure occurs before gap measurement")
    }

    func testStopFromGapExpressionWinsAfterWriterInstallButBeforeSegmentRegistration() throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        var gapStop: ArtifactTestTicket?
        var evaluations = 0
        func stopAtGap() -> TimeInterval {
            evaluations += 1
            XCTAssertEqual(f.writer.writerOwned(by: a.captureGeneration)?.url.lastPathComponent, "artifact-2.wav")
            f.effects.log.append("stop-at-gap")
            gapStop = f.owner.sealStop(expectedCaptureGeneration: a.captureGeneration)
            if let gapStop { f.owner.commitStopSystemHandoff(gapStop, url: nil) }
            return 8.5
        }
        guard case .notOwned = try f.transactions.createRecovery(context: a, prepared: 44_100, gapBefore: stopAtGap()) else {
            return XCTFail("Stop inside the gap expression must precede registration's generation cutoff")
        }
        let ticket = try XCTUnwrap(gapStop)
        let snapshot = f.close(ticket)
        XCTAssertEqual(evaluations, 1)
        XCTAssertEqual(snapshot.segments.map(\.url.lastPathComponent), ["artifact-1.wav"])
        assertArtifactOrder([
            "create:artifact-2.wav", "stop-at-gap", "close-done:artifact-2.wav", "remove:artifact-2.wav"
        ], in: f.effects.log.values)
    }
}

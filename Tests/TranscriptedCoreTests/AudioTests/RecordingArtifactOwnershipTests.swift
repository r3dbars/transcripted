import Foundation
import XCTest
@testable import TranscriptedCore

final class RecordingArtifactOwnershipTests: XCTestCase {
    func testStopBeforeInitialAdmissionCreatesNoFileOrJournal() throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        let ticket = try f.seal(a)
        guard case .stale = try f.transactions.createInitial(context: a, prepared: 48_000) else {
            return XCTFail("Stop must reject initial setup before its first effect")
        }
        guard case .stale = try f.transactions.createInitial(context: a, prepared: 48_000) else {
            return XCTFail("repeated stale admission must remain rejected")
        }
        let snapshot = f.close(ticket)
        XCTAssertNil(snapshot.primaryURL)
        XCTAssertTrue(snapshot.segments.isEmpty)
        XCTAssertNil(snapshot.binding)
        XCTAssertEqual(snapshot.allowedRoot, f.effects.allowedRoot)
        XCTAssertTrue(f.effects.log.values.isEmpty)
    }

    func testContextAndSealAreVisibleBeforePersistentAdvanceHookRuns() throws {
        let f = ArtifactTestFixture()
        var observed: [UInt64] = []
        f.clock.afterAdvanceForTesting = { generation in
            observed.append(generation)
            XCTAssertEqual(f.clock.current, generation)
            // Reacquiring the SAME generation authority is safe only if the
            // production transition released it before invoking this hook.
            XCTAssertNotEqual(f.clock.predictedNext(), generation)
            if let current = f.owner.currentContext(), current.captureGeneration == generation {
                XCTAssertEqual(current.endpoint.id, observed.count == 1 ? 1 : 2)
            } else if let current = f.owner.currentContext() {
                XCTAssertFalse(f.owner.admitRecoveryTransaction(current), "sealed context must already reject setup")
                XCTAssertEqual(f.clock.inFlightStopGeneration, generation)
            } else {
                XCTFail("hook must not observe a published generation without its context")
            }
        }
        let a = f.context(1)
        let stop = try f.seal(a)
        let b = f.context(2)
        XCTAssertEqual(observed, [a.captureGeneration, stop.stopGeneration, b.captureGeneration])
        XCTAssertNil(f.clock.inFlightStopGeneration, "an old stop does not own the new epoch")
        f.clock.afterAdvanceForTesting = nil
    }

    func testDiscardChosenBeforeStopRejectsAbandonmentAndDuplicateDiscard() throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        guard case .selected = f.owner.requestDiscard(context: a) else { return XCTFail("first D should select") }
        guard case .alreadySelected = f.owner.requestDiscard(context: a) else { return XCTFail("D is idempotent") }
        let stop = try f.seal(a)
        guard case .rejectedDiscardOwner = f.owner.requestAbandon(stopGeneration: stop.stopGeneration) else {
            return XCTFail("expiry/prune must not override a confirmed discard")
        }
        guard case .rejectedDiscardOwner = f.owner.requestAbandon(stopGeneration: stop.stopGeneration) else {
            return XCTFail("a later repeat cannot turn D into R")
        }
    }

    func testRecoveryChosenFirstRejectsDiscardAndDuplicateOrUnknownAbandonment() throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        let stop = try f.seal(a)
        guard case .selected = f.owner.requestAbandon(stopGeneration: stop.stopGeneration) else {
            return XCTFail("owned Stop should accept R once, including nil token")
        }
        guard case .rejectedRecoveryOwner = f.owner.requestDiscard(context: a) else { return XCTFail("D cannot replace R") }
        guard case .alreadySelected = f.owner.requestAbandon(stopGeneration: stop.stopGeneration) else { return XCTFail("R is idempotent") }
        guard case .notOwned = f.owner.requestAbandon(stopGeneration: 9_999) else { return XCTFail("wrong identity owns nothing") }
        XCTAssertTrue(f.effects.log.values.isEmpty, "memory ownership decisions do not release or delete")
    }

    func testClaimedNormalFinalizerRejectsAbandonmentButAcceptsPendingDiscard() throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        let stop = try f.seal(a)
        _ = f.close(stop)
        guard case .normal = f.owner.claimQuiescentFinalization(stop) else { return XCTFail("normal owner should claim") }
        guard case .finalizerOwned = f.owner.requestAbandon(stopGeneration: stop.stopGeneration) else {
            return XCTFail("R cannot replace a claimed merger")
        }
        guard case .selected = f.owner.requestDiscard(context: a) else {
            return XCTFail("D can wait for the already claimed normal finalizer")
        }
        switch f.owner.requestAbandon(stopGeneration: stop.stopGeneration) {
        case .rejectedDiscardOwner, .finalizerOwned: break
        default: XCTFail("neither pending D nor a claimed finalizer permits R")
        }
    }

    func testSystemBeforeAndAfterInitialSetupUsesExactEndpointAndPreservesURL() throws {
        for systemFirst in [true, false] {
            let f = ArtifactTestFixture()
            let a = f.context(1, language: "frozen-a", micOnly: false)
            let system = f.effects.root.appendingPathComponent("system-a.wav")
            if systemFirst { XCTAssertTrue(f.owner.bindSystemCandidate(a, url: system)) }
            try f.start(a)
            if !systemFirst { XCTAssertTrue(f.owner.bindSystemCandidate(a, url: system)) }
            f.flushJournal()
            XCTAssertEqual(a.endpoint.inventory?.finalSystemURL, system)
            let stop = try f.seal(a, systemURL: system)
            let snapshot = f.close(stop)
            XCTAssertEqual(snapshot.finalSystemURL, system)
            XCTAssertTrue(snapshot.binding?.endpoint === a.endpoint)
            XCTAssertEqual(snapshot.binding?.token, 1)
            XCTAssertEqual(snapshot.allowedRoot, f.effects.allowedRoot)
            XCTAssertNotEqual(snapshot.allowedRoot, try XCTUnwrap(snapshot.primaryURL).deletingLastPathComponent(), "managed root is supplied, not inferred from artifact parent")
        }
    }

    func testAuthoritativeNilSystemHandoffCannotFallBackToCandidateOrSuccessor() throws {
        let f = ArtifactTestFixture()
        let a = f.context(1)
        let oldCandidate = f.effects.root.appendingPathComponent("candidate-a.wav")
        XCTAssertTrue(f.owner.bindSystemCandidate(a, url: oldCandidate))
        try f.start(a)
        let stop = try f.seal(a, systemURL: nil)
        XCTAssertFalse(f.owner.bindSystemCandidate(a, url: oldCandidate), "stale publication cannot undo authoritative nil")
        let b = f.context(2)
        let systemB = f.effects.root.appendingPathComponent("system-b.wav")
        XCTAssertTrue(f.owner.bindSystemCandidate(b, url: systemB))
        let snapshotA = f.close(stop)
        XCTAssertNil(snapshotA.finalSystemURL)
        XCTAssertEqual(snapshotA.binding?.token, 1)
        XCTAssertEqual(b.facts, ArtifactTestFacts(language: "a", micOnly: false))
        XCTAssertTrue(f.owner.currentContext() === b)
    }

    func testNilStopHandoffClearsAnEarlierJournaledCandidateBeforeStopping() throws {
        let f = ArtifactTestFixture()
        let a = f.context(1)
        try f.start(a)
        let candidate = f.effects.root.appendingPathComponent("candidate.wav")
        XCTAssertTrue(f.owner.bindSystemCandidate(a, url: candidate))
        f.flushJournal()
        XCTAssertEqual(a.endpoint.inventory?.finalSystemURL, candidate)
        let stop = try f.seal(a, systemURL: nil)
        _ = f.close(stop)
        f.flushJournal()
        XCTAssertNil(a.endpoint.inventory?.finalSystemURL)
        assertArtifactOrder(["system:1", "clear-system:1", "stopping:1"], in: f.effects.log.values)
        XCTAssertFalse(f.owner.bindSystemCandidate(a, url: candidate))
    }
}

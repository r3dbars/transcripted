import Foundation
import XCTest
@testable import TranscriptedCore

final class RecordingArtifactCompletionTests: XCTestCase {
    func testPendingDiscardCleansActualMergedInventoryBeforeReleaseAndOneCompletion() async throws {
        for succeeds in [true, false] {
            let f = ArtifactTestFixture()
            let a = f.context()
            let journalURL = f.effects.root.appendingPathComponent("opaque-record.journal")
            let journalData = Data([0x00, 0xff, 0x7b, 0x80, 0x0a])
            f.effects.initialJournalURL = journalURL
            f.effects.initialJournalData = journalData
            try f.start(a)
            f.effects.cleanupSucceeds = succeeds
            let cleanupGate = ArtifactTestGate("safe cleanup held before returning")
            let cleanupLog = f.effects.log
            defer { cleanupGate.open() }
            f.effects.onCleanup = {
                cleanupGate.pause()
                cleanupLog.append("cleanup-return-boundary")
            }
            guard case .selected = f.completion.requestDiscard(context: a) else { return XCTFail("D should select before Stop") }
            let system = f.effects.root.appendingPathComponent("system.wav")
            let stop = try f.seal(a, systemURL: system)
            let done = expectation(description: "discard completion after release")
            f.schedule(stop, done: done)
            await fulfillment(of: [cleanupGate.entered], timeout: 20)
            f.journalQueue.sync {
                XCTAssertTrue(a.endpoint.liveClaim, "pending D must retain its claim until safeCleanup returns")
                f.effects.log.append("claim-during-cleanup:\(a.endpoint.liveClaim)")
            }
            f.callbacks.sync {}
            XCTAssertFalse(f.effects.log.values.contains("discard-release:1:\(succeeds)"))
            XCTAssertFalse(f.effects.log.values.contains("before:a"), "cleanup entry is not cleanup completion")
            cleanupGate.open()
            await fulfillment(of: [done], timeout: 20)
            f.flushJournal()
            let cleanup = try XCTUnwrap(f.effects.log.cleanups.first)
            XCTAssertEqual(f.effects.log.cleanups.count, 1)
            XCTAssertEqual(cleanup.primaryURL?.lastPathComponent, "artifact-1.wav")
            XCTAssertEqual(cleanup.finalMicURL?.lastPathComponent, "artifact-1.wav.merged")
            XCTAssertEqual(cleanup.finalSystemURL, system)
            XCTAssertEqual(cleanup.allowedRoot, f.effects.allowedRoot)
            XCTAssertEqual(cleanup.journalURL, journalURL)
            XCTAssertEqual(cleanup.journalData, journalData, "safeCleanup receives cached opaque bytes unchanged")
            XCTAssertFalse(a.endpoint.liveClaim)
            assertArtifactOrder([
                "finalized:1:false", "snapshot:1", "cleanup:artifact-1.wav.merged",
                "claim-during-cleanup:true", "cleanup-return-boundary", "discard-release:1:\(succeeds)",
                "before:a", "timeline:a", "generation:a", "legacy:a"
            ], in: f.effects.log.values)
            XCTAssertFalse(f.effects.log.values.contains("release-enter:1"), "failed cleanup is not R")
            XCTAssertEqual(f.effects.log.outputs.count, 1)
            XCTAssertEqual(f.effects.log.outputs.first?.disposition, .finalized)
            guard case .alreadySelected = f.completion.requestDiscard(context: a) else { return XCTFail("duplicate D is idempotent") }
            f.work.sync {}; f.flushJournal(); f.callbacks.sync {}
            XCTAssertEqual(f.effects.log.cleanups.count, 1)
            XCTAssertEqual(f.effects.log.outputs.count, 1)
        }
    }

    func testDiscardSelectedWhileNormalMergerIsClaimedIsRecheckedBeforeRelease() async throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        let mergeGate = ArtifactTestGate("normal merger claimed")
        f.effects.onMerge = { mergeGate.pause() }
        defer { mergeGate.open() }
        let stop = try f.seal(a)
        let done = expectation(description: "late D completed")
        f.schedule(stop, done: done)
        await fulfillment(of: [mergeGate.entered], timeout: 20)
        guard case .finalizerOwned = f.owner.requestAbandon(stopGeneration: stop.stopGeneration) else {
            return XCTFail("a claimed normal merger cannot transfer to R")
        }
        guard case .selected = f.completion.requestDiscard(context: a) else { return XCTFail("D must be remembered after initial normal claim") }
        mergeGate.open()
        await fulfillment(of: [done], timeout: 20)
        XCTAssertFalse(f.effects.log.values.contains("finalized:1:true"), "the earlier normal claim must not choose ordinary release")
        assertArtifactOrder(["finalized:1:false", "cleanup:artifact-1.wav.merged", "discard-release:1:true", "before:a"], in: f.effects.log.values)
    }

    func testMissingExactJournalInventoryDoesNotInventADeletionScope() async throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        f.effects.snapshotMissing = true
        guard case .selected = f.completion.requestDiscard(context: a) else { return XCTFail("D should select") }
        let stop = try f.seal(a)
        let done = expectation(description: "failed closed inventory completes")
        f.schedule(stop, done: done)
        await fulfillment(of: [done], timeout: 20)
        XCTAssertTrue(f.effects.log.cleanups.isEmpty)
        assertArtifactOrder(["snapshot:1", "discard-release:1:false", "before:a"], in: f.effects.log.values)
        XCTAssertFalse(f.effects.log.values.contains("release-enter:1"))
        XCTAssertEqual(f.effects.log.outputs.count, 1)
    }

    func testRecoveryReleaseMustFinishBeforeOriginalCallbackOrderAndCannotBecomeDiscard() async throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        let system = f.effects.root.appendingPathComponent("system-a.wav")
        let stop = try f.seal(a, systemURL: system)
        guard case .selected = f.owner.requestAbandon(stopGeneration: stop.stopGeneration) else { return XCTFail("R should select") }
        let releaseGate = ArtifactTestGate("exact R release entered")
        f.effects.onRelease = { releaseGate.pause() }
        defer { releaseGate.open() }
        let done = expectation(description: "R completion after exact release")
        f.schedule(stop, done: done)
        await fulfillment(of: [releaseGate.entered], timeout: 20)
        f.work.sync {}
        f.callbacks.sync {}
        XCTAssertFalse(f.effects.log.values.contains("before:a"))
        XCTAssertTrue(f.effects.log.cleanups.isEmpty)
        XCTAssertFalse(f.effects.log.values.contains("merge:\(stop.stopGeneration)"))
        guard case .rejectedRecoveryOwner = f.completion.requestDiscard(context: a) else { return XCTFail("D cannot replace pending R") }
        let b = f.context(2, language: "b", micOnly: true)
        releaseGate.open()
        await fulfillment(of: [done], timeout: 20)
        assertArtifactOrder(["release-done:1", "before:a", "timeline:a", "generation:a", "legacy:a"], in: f.effects.log.values)
        XCTAssertNil(f.effects.log.outputs.first?.micURL)
        XCTAssertEqual(f.effects.log.outputs.first?.systemURL, system)
        XCTAssertEqual(f.effects.log.outputs.first?.disposition, .journalRecoveryOwned)
        switch f.completion.requestDiscard(context: a) {
        case .rejectedRecoveryOwner, .notOwned: break
        default: XCTFail("released or retired A cannot become current discard")
        }
        XCTAssertTrue(f.owner.currentContext() === b)
        XCTAssertEqual(b.facts, ArtifactTestFacts(language: "b", micOnly: true))
        XCTAssertNil(b.endpoint.inventory)
        XCTAssertTrue(f.effects.log.cleanups.isEmpty)
    }

    func testAbandonBeforeLateInitialTokenWaitsForDrainAndReleasesThatExactToken() async throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        let beginGate = ArtifactTestGate("initial before token")
        f.effects.onBegin = { beginGate.pause() }
        defer { beginGate.open() }
        let started = expectation(description: "late admitted initial completed")
        let result = ArtifactTestResult<Void>()
        DispatchQueue.global().async { result.set(Result { try f.start(a) }); started.fulfill() }
        await fulfillment(of: [beginGate.entered], timeout: 20)
        let stop = try f.seal(a)
        guard case .selected = f.owner.requestAbandon(stopGeneration: stop.stopGeneration) else { return XCTFail("nil token must still accept owned R") }
        let done = expectation(description: "late token released")
        let systemClosed = expectation(description: "system branch independent of pending begin")
        f.schedule(stop, done: done, closeSystem: { systemClosed.fulfill() })
        await fulfillment(of: [systemClosed], timeout: 20)
        XCTAssertFalse(f.effects.log.values.contains("release-enter:1"))
        XCTAssertFalse(f.effects.log.values.contains("before:a"))
        beginGate.open()
        await fulfillment(of: [started, done], timeout: 20)
        try result.get()
        assertArtifactOrder(["begin:1:a:false", "close-done:artifact-1.wav", "release-done:1", "before:a"], in: f.effects.log.values)
        XCTAssertFalse(a.endpoint.liveClaim)
    }

    func testNoTokenDiscardCleansHandedOffSystemOnlyInventoryAndCompletesOnce() async throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        guard case .selected = f.completion.requestDiscard(context: a) else {
            return XCTFail("current system-only recording can select D before Stop")
        }
        let system = f.effects.root.appendingPathComponent("system-only.wav")
        let stop = try f.seal(a, systemURL: system)
        let done = expectation(description: "system-only D completion")
        f.schedule(stop, done: done)
        await fulfillment(of: [done], timeout: 20)
        f.work.sync {}; f.flushJournal(); f.callbacks.sync {}
        XCTAssertEqual(f.effects.log.cleanups.count, 1)
        let cleanup = try XCTUnwrap(f.effects.log.cleanups.first)
        XCTAssertEqual(cleanup.finalSystemURL, system)
        XCTAssertEqual(cleanup.allowedRoot, f.effects.allowedRoot)
        XCTAssertNil(cleanup.primaryURL)
        XCTAssertNil(cleanup.finalMicURL)
        XCTAssertTrue(cleanup.segments.isEmpty)
        XCTAssertNil(cleanup.journalURL)
        XCTAssertNil(cleanup.journalData)
        XCTAssertNil(a.endpoint.inventory)
        XCTAssertFalse(a.endpoint.liveClaim)
        XCTAssertFalse(f.effects.log.values.contains {
            $0.hasPrefix("begin:") || $0.hasPrefix("snapshot:") ||
            $0.hasPrefix("finalized:") || $0.hasPrefix("discard-release:") ||
            $0.hasPrefix("release-")
        }, "no mic journal binding or physical claim release may be invented")
        let output = try XCTUnwrap(f.effects.log.outputs.first)
        XCTAssertEqual(output.stopGeneration, stop.stopGeneration)
        XCTAssertNil(output.micURL)
        XCTAssertEqual(output.systemURL, system)
        XCTAssertEqual(output.disposition, .finalized)
        XCTAssertEqual(f.effects.log.outputs.count, 1)
        assertArtifactOrder(["cleanup:nil", "before:a", "timeline:a", "generation:a", "legacy:a"],
                            in: f.effects.log.values)
        for edge in ["before:a", "timeline:a", "generation:a", "legacy:a"] {
            XCTAssertEqual(f.effects.log.values.filter { $0 == edge }.count, 1)
        }
    }

    func testNoTokenRecoveryCompletesOnceWithoutMergeDeleteOrFakeRelease() async throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        let stop = try f.seal(a)
        guard case .selected = f.owner.requestAbandon(stopGeneration: stop.stopGeneration) else { return XCTFail("owned empty Stop can select R") }
        let done = expectation(description: "empty R completion")
        f.schedule(stop, done: done)
        await fulfillment(of: [done], timeout: 20)
        XCTAssertEqual(f.effects.log.outputs.count, 1)
        let output = try XCTUnwrap(f.effects.log.outputs.first)
        XCTAssertNil(output.micURL)
        XCTAssertNil(output.systemURL)
        XCTAssertEqual(output.disposition, .journalRecoveryOwned)
        XCTAssertTrue(f.effects.log.cleanups.isEmpty)
        XCTAssertFalse(f.effects.log.values.contains { $0.hasPrefix("release-") || $0.hasPrefix("merge:") })
        let duplicate = XCTestExpectation(description: "duplicate delivery must not occur")
        f.completion.afterOwnedArtifactsDrained(stop, callbacks: f.edges("duplicate", done: duplicate))
        f.work.sync {}; f.flushJournal(); f.work.sync {}; f.callbacks.sync {}
        XCTAssertEqual(f.effects.log.outputs.count, 1)
        XCTAssertFalse(f.effects.log.values.contains("before:duplicate"))
    }

    func testCompatibilityDiscardBeforeAndAfterCallbackDeliveryNeverRepeatsStopEdges() async throws {
        for holdDelivery in [true, false] {
            let f = ArtifactTestFixture()
            let a = f.context()
            try f.start(a)
            let callbackGate = ArtifactTestGate("callback queue held")
            if holdDelivery { f.callbacks.async { callbackGate.pause() } }
            defer { callbackGate.open() }
            if holdDelivery { await fulfillment(of: [callbackGate.entered], timeout: 20) }
            let stop = try f.seal(a)
            let done = expectation(description: "one original normal completion")
            let applied = expectation(description: "normal release applied")
            f.effects.onFinalized = { endingSession in if endingSession { applied.fulfill() } }
            f.schedule(stop, done: done)
            if holdDelivery {
                await fulfillment(of: [applied], timeout: 20)
                f.work.sync {}
            } else {
                await fulfillment(of: [applied, done], timeout: 20)
            }
            let cleanup = expectation(description: "compatibility cleanup")
            f.effects.onCleanup = { cleanup.fulfill() }
            guard case .selected = f.completion.requestDiscard(context: a) else { return XCTFail("completed current normal context permits explicit discard") }
            await fulfillment(of: [cleanup], timeout: 20)
            f.work.sync {}; f.flushJournal()
            callbackGate.open()
            if holdDelivery { await fulfillment(of: [done], timeout: 20) }
            f.callbacks.sync {}
            XCTAssertEqual(f.effects.log.outputs.count, 1)
            XCTAssertEqual(f.effects.log.values.filter { $0 == "timeline:a" }.count, 1)
            XCTAssertEqual(f.effects.log.values.filter { $0 == "generation:a" }.count, 1)
            XCTAssertEqual(f.effects.log.values.filter { $0 == "legacy:a" }.count, 1)
        }
    }

    func testPerTicketEdgesKeepAAndBAttachmentsWhenBFinishesDuringAHeldRelease() async throws {
        let f = ArtifactTestFixture()
        let a = f.context(1)
        try f.start(a)
        let systemA = f.effects.root.appendingPathComponent("system-a.wav")
        let stopA = try f.seal(a, systemURL: systemA)
        guard case .selected = f.owner.requestAbandon(stopGeneration: stopA.stopGeneration) else { return XCTFail("A should select R") }
        let release = ArtifactTestGate("A release held")
        let delivery = ArtifactTestGate("ticket delivery held")
        defer { release.open(); delivery.open() }
        f.effects.onRelease = { release.pause() }
        f.callbacks.async { delivery.pause() }
        await fulfillment(of: [delivery.entered], timeout: 20)
        let aDone = expectation(description: "A own edges")
        f.schedule(stopA, done: aDone, label: "a")
        await fulfillment(of: [release.entered], timeout: 20)

        // B's empty mic context needs no journal begin and can finish while
        // A's exact journal release is held. Its handoff is synthetic input.
        let b = f.context(2)
        let systemB = f.effects.root.appendingPathComponent("system-b.wav")
        let stopB = try f.seal(b, systemURL: systemB)
        let bMerged = expectation(description: "B normal finalizer ran")
        f.effects.onMerge = { bMerged.fulfill() }
        let bDone = expectation(description: "B own edges")
        f.schedule(stopB, done: bDone, label: "b")
        await fulfillment(of: [bMerged], timeout: 20)
        f.work.sync {}
        release.open()
        f.flushJournal(); f.work.sync {}
        delivery.open()
        await fulfillment(of: [aDone, bDone], timeout: 20)
        let aOutput = try XCTUnwrap(f.effects.log.outputs.first { $0.stopGeneration == stopA.stopGeneration })
        let bOutput = try XCTUnwrap(f.effects.log.outputs.first { $0.stopGeneration == stopB.stopGeneration })
        XCTAssertEqual(aOutput.systemURL, systemA)
        XCTAssertEqual(bOutput.systemURL, systemB)
        XCTAssertEqual(aOutput.disposition, .journalRecoveryOwned)
        XCTAssertEqual(bOutput.disposition, .finalized)
        XCTAssertEqual(f.effects.log.outputs.count, 2)
        for label in ["a", "b"] {
            assertArtifactOrder(["before:\(label)", "timeline:\(label)", "generation:\(label)", "legacy:\(label)"], in: f.effects.log.values)
            XCTAssertEqual(f.effects.log.values.filter { $0 == "timeline:\(label)" }.count, 1)
        }
    }

    func testRealSchedulerDoesNotLetHeldMicProducerOrHostFanoutBlockSystemClose() async throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        let stop = try f.seal(a)
        let producer = ArtifactTestGate("mic producer held")
        let host = DispatchGroup()
        host.enter()
        defer { producer.open() }
        let systemClosed = expectation(description: "system writer closes independently")
        let done = expectation(description: "all drains before completion")
        f.schedule(stop, done: done, group: host, stopMic: { producer.pause() }, closeSystem: { systemClosed.fulfill() })
        await fulfillment(of: [producer.entered, systemClosed], timeout: 20)
        XCTAssertFalse(f.effects.log.values.contains("close-done:artifact-1.wav"))
        XCTAssertFalse(f.effects.log.values.contains("before:a"))
        producer.open()
        f.mic.sync {}
        XCTAssertFalse(f.effects.log.values.contains("before:a"), "host drain still owns the completion group")
        host.leave()
        await fulfillment(of: [done], timeout: 20)
        assertArtifactOrder(["close-done:artifact-1.wav", "before:a", "timeline:a", "generation:a", "legacy:a"], in: f.effects.log.values)
    }

    func testRealSchedulerLetsMicCloseWhileSystemProducerIsHeld() async throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        let stop = try f.seal(a)
        let producer = ArtifactTestGate("system producer held")
        defer { producer.open() }
        let micClosed = expectation(description: "independent mic explicit close")
        f.effects.onClose = { micClosed.fulfill() }
        let done = expectation(description: "system drain completes Stop")
        f.schedule(stop, done: done, stopSystem: { producer.pause() })
        await fulfillment(of: [producer.entered, micClosed], timeout: 20)
        XCTAssertFalse(f.effects.log.values.contains("before:a"))
        producer.open()
        await fulfillment(of: [done], timeout: 20)
    }

    func testRealSchedulerWaitsForBothSerialWriterTailsBeforeCompletion() async throws {
        let f = ArtifactTestFixture()
        let a = f.context()
        try f.start(a)
        let stop = try f.seal(a)
        let micTail = ArtifactTestGate("admitted mic queue tail")
        let systemTail = ArtifactTestGate("admitted system queue tail")
        defer { micTail.open(); systemTail.open() }
        f.mic.async { micTail.pause() }
        f.system.async { systemTail.pause() }
        await fulfillment(of: [micTail.entered, systemTail.entered], timeout: 20)
        let producerStops = expectation(description: "both producers returned")
        producerStops.expectedFulfillmentCount = 2
        let done = expectation(description: "writer tails drained")
        f.schedule(stop, done: done, stopMic: { producerStops.fulfill() }, stopSystem: { producerStops.fulfill() })
        await fulfillment(of: [producerStops], timeout: 20)
        XCTAssertFalse(f.effects.log.values.contains("close-done:artifact-1.wav"))
        XCTAssertFalse(f.effects.log.values.contains("before:a"))
        micTail.open()
        f.mic.sync {}
        XCTAssertFalse(f.effects.log.values.contains("before:a"), "system tail still prevents completion")
        systemTail.open()
        await fulfillment(of: [done], timeout: 20)
        assertArtifactOrder(["close-done:artifact-1.wav", "before:a"], in: f.effects.log.values)
    }
}

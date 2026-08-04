import XCTest
@testable import TranscriptedCore

/// Coverage for `SupersessionEpoch` and `ClaimSlot`, including wraparound and the
/// `predictedNext()` prediction-then-begin handshake. See doc comments on
/// `Sources/TranscriptedCore/Utilities/SupersessionEpoch.swift` for the tree
/// patterns each operation's semantics are anchored to.
final class SupersessionEpochTests: XCTestCase {

    // MARK: - begin()

    func testBeginStartsAtGenerationOneFromZeroInitialState() {
        var epoch = SupersessionEpoch()
        XCTAssertEqual(epoch.current.rawValue, 0)
        let token = epoch.begin()
        XCTAssertEqual(token.rawValue, 1)
        XCTAssertEqual(epoch.current, token)
    }

    func testBeginProducesDistinctTokensEachCall() {
        var epoch = SupersessionEpoch()
        let first = epoch.begin()
        let second = epoch.begin()
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(epoch.isCurrent(second))
        XCTAssertFalse(epoch.isCurrent(first))
    }

    // MARK: - snapshot()

    func testSnapshotReadsCurrentWithoutBumping() {
        var epoch = SupersessionEpoch()
        let started = epoch.begin()
        let snapshot = epoch.snapshot()
        XCTAssertEqual(snapshot, started)
        // Snapshotting must not itself advance the epoch.
        XCTAssertEqual(epoch.snapshot(), started)
        XCTAssertTrue(epoch.isCurrent(started))
    }

    func testSnapshotBeforeAnyBeginReadsZeroGeneration() {
        let epoch = SupersessionEpoch()
        XCTAssertEqual(epoch.snapshot().rawValue, 0)
    }

    // MARK: - isCurrent(_:)

    func testIsCurrentIsPureAndRepeatable() {
        var epoch = SupersessionEpoch()
        let token = epoch.begin()
        // Calling isCurrent repeatedly must never consume or mutate anything —
        // mirrors WhisperEngine.load(model:generation:)'s several independent
        // guard checks against one captured generation.
        for _ in 0..<5 {
            XCTAssertTrue(epoch.isCurrent(token))
        }
    }

    func testIsCurrentFalseAfterSupersession() {
        var epoch = SupersessionEpoch()
        let first = epoch.begin()
        _ = epoch.begin()
        XCTAssertFalse(epoch.isCurrent(first))
    }

    // MARK: - invalidate()

    func testInvalidateBumpsAndFencesOutPreviousToken() {
        var epoch = SupersessionEpoch()
        let token = epoch.begin()
        XCTAssertTrue(epoch.isCurrent(token))
        epoch.invalidate()
        XCTAssertFalse(epoch.isCurrent(token))
    }

    func testInvalidateWithNoPriorBeginStillAdvancesFromZero() {
        var epoch = SupersessionEpoch()
        XCTAssertEqual(epoch.current.rawValue, 0)
        epoch.invalidate()
        XCTAssertEqual(epoch.current.rawValue, 1)
    }

    func testDoubleInvalidateFencesOutAnyPreviouslyCapturedToken() {
        var epoch = SupersessionEpoch()
        let token = epoch.begin()
        epoch.invalidate()
        epoch.invalidate()
        XCTAssertFalse(epoch.isCurrent(token))
    }

    // MARK: - finishIfCurrent(_:)

    func testFinishIfCurrentReturnsTrueAndLeavesEpochOpenForNewWork() {
        var epoch = SupersessionEpoch()
        let token = epoch.begin()
        XCTAssertTrue(epoch.finishIfCurrent(token))
        // The epoch must stay open — a stale-completion guard, not a reset.
        XCTAssertEqual(epoch.current, token)
        XCTAssertTrue(epoch.isCurrent(token))
    }

    func testFinishIfCurrentReturnsFalseWithoutBumpingWhenStale() {
        var epoch = SupersessionEpoch()
        let first = epoch.begin()
        let second = epoch.begin()
        XCTAssertFalse(epoch.finishIfCurrent(first))
        // A failed finish must not mutate the epoch at all.
        XCTAssertEqual(epoch.current, second)
        XCTAssertTrue(epoch.isCurrent(second))
    }

    func testFinishIfCurrentCanBeCalledAgainAfterSuccessSinceItDidNotConsume() {
        var epoch = SupersessionEpoch()
        let token = epoch.begin()
        XCTAssertTrue(epoch.finishIfCurrent(token))
        XCTAssertTrue(epoch.finishIfCurrent(token))
    }

    // MARK: - supersedeIfCurrent(_:)

    func testSupersedeIfCurrentBumpsAndFencesOutTheWinningTokenItself() {
        var epoch = SupersessionEpoch()
        let token = epoch.begin()
        XCTAssertTrue(epoch.supersedeIfCurrent(token))
        // Unlike finishIfCurrent, the winning token itself is now stale — the
        // bump moved the epoch past it, matching
        // ParakeetRecoveryState.timeoutRecovery(generation:).
        XCTAssertFalse(epoch.isCurrent(token))
    }

    func testSupersedeIfCurrentReturnsFalseWithoutBumpingWhenAlreadyStale() {
        var epoch = SupersessionEpoch()
        let first = epoch.begin()
        let second = epoch.begin()
        XCTAssertFalse(epoch.supersedeIfCurrent(first))
        XCTAssertEqual(epoch.current, second)
        XCTAssertTrue(epoch.isCurrent(second))
    }

    func testSupersedeIfCurrentThenAnyOtherHolderOfThatTokenIsAlsoFencedOut() {
        var epoch = SupersessionEpoch()
        let token = epoch.begin()
        let concurrentHolder = epoch.snapshot()
        XCTAssertTrue(epoch.supersedeIfCurrent(token))
        XCTAssertFalse(epoch.isCurrent(concurrentHolder))
        XCTAssertFalse(epoch.finishIfCurrent(concurrentHolder))
    }

    // MARK: - predictedNext()

    func testPredictedNextMatchesTheTokenAnImmediatelyFollowingBeginProduces() {
        var epoch = SupersessionEpoch()
        _ = epoch.begin()
        let predicted = epoch.predictedNext()
        let actual = epoch.begin()
        XCTAssertEqual(predicted, actual)
    }

    func testPredictedNextDoesNotItselfMutateTheEpoch() {
        var epoch = SupersessionEpoch()
        let before = epoch.snapshot()
        _ = epoch.predictedNext()
        XCTAssertEqual(epoch.snapshot(), before)
    }

    func testPredictedNextBecomesStaleIfSomethingElseBumpsFirst() {
        // Names the hazard called out in the doc comment: a prediction is only
        // valid until the next mutating call. If something else invalidates the
        // epoch between the prediction and the expected mint, the prediction no
        // longer matches.
        var epoch = SupersessionEpoch()
        let predicted = epoch.predictedNext()
        epoch.invalidate()
        let actual = epoch.begin()
        XCTAssertNotEqual(predicted, actual)
    }

    // MARK: - wraparound

    func testBeginWrapsAroundAtUInt64MaxUsingOverflowSafeArithmetic() {
        var epoch = SupersessionEpoch()
        epoch.forceCurrent(rawValue: .max)
        let wrapped = epoch.begin()
        XCTAssertEqual(wrapped.rawValue, 0)
        XCTAssertTrue(epoch.isCurrent(wrapped))
    }

    func testInvalidateWrapsAroundAtUInt64Max() {
        var epoch = SupersessionEpoch()
        epoch.forceCurrent(rawValue: .max)
        epoch.invalidate()
        XCTAssertEqual(epoch.current.rawValue, 0)
    }

    func testSupersedeIfCurrentWrapsAroundAtUInt64Max() {
        var epoch = SupersessionEpoch()
        epoch.forceCurrent(rawValue: .max)
        let token = epoch.current
        XCTAssertTrue(epoch.supersedeIfCurrent(token))
        XCTAssertEqual(epoch.current.rawValue, 0)
    }

    func testPredictedNextWrapsAroundAtUInt64Max() {
        var epoch = SupersessionEpoch()
        epoch.forceCurrent(rawValue: .max)
        XCTAssertEqual(epoch.predictedNext().rawValue, 0)
    }

    // MARK: - Equatable

    func testSupersessionEpochEqualityIsByCurrentToken() {
        var lhs = SupersessionEpoch()
        var rhs = SupersessionEpoch()
        XCTAssertEqual(lhs, rhs)
        _ = lhs.begin()
        XCTAssertNotEqual(lhs, rhs)
        _ = rhs.begin()
        XCTAssertEqual(lhs, rhs)
    }
}

// MARK: - ClaimSlot

final class ClaimSlotTests: XCTestCase {

    func testInstallStoresPayloadRetrievableByItsOwningToken() {
        var epoch = SupersessionEpoch()
        var slot = ClaimSlot<String>()
        let token = epoch.begin()
        XCTAssertNil(slot.install("first", ownedBy: token))
        XCTAssertEqual(slot.peekIfOwned(by: token), "first")
    }

    func testInstallReturnsDisplacedPayloadRegardlessOfPriorOwner() {
        var epoch = SupersessionEpoch()
        var slot = ClaimSlot<String>()
        let first = epoch.begin()
        _ = slot.install("first", ownedBy: first)
        let second = epoch.begin()
        let displaced = slot.install("second", ownedBy: second)
        XCTAssertEqual(displaced, "first")
        XCTAssertEqual(slot.peekIfOwned(by: second), "second")
        XCTAssertNil(slot.peekIfOwned(by: first))
    }

    func testTakeIfOwnedConsumesOnlyOnMatchingToken() {
        var epoch = SupersessionEpoch()
        var slot = ClaimSlot<Int>()
        let stale = epoch.begin()
        let current = epoch.begin()
        _ = slot.install(42, ownedBy: current)

        XCTAssertNil(slot.takeIfOwned(by: stale))
        // A failed take must not disturb the stored payload.
        XCTAssertEqual(slot.peekIfOwned(by: current), 42)

        XCTAssertEqual(slot.takeIfOwned(by: current), 42)
        // A successful take empties the slot.
        XCTAssertNil(slot.peekIfOwned(by: current))
    }

    func testPeekIfOwnedDoesNotConsume() {
        var epoch = SupersessionEpoch()
        var slot = ClaimSlot<Int>()
        let token = epoch.begin()
        _ = slot.install(7, ownedBy: token)
        XCTAssertEqual(slot.peekIfOwned(by: token), 7)
        XCTAssertEqual(slot.peekIfOwned(by: token), 7)
    }

    func testClearReturnsAndRemovesRegardlessOfOwner() {
        var epoch = SupersessionEpoch()
        var slot = ClaimSlot<Int>()
        let token = epoch.begin()
        _ = slot.install(99, ownedBy: token)
        XCTAssertEqual(slot.clear(), 99)
        XCTAssertNil(slot.clear())
        XCTAssertNil(slot.peekIfOwned(by: token))
    }

    func testClearIfOwnedOnlyClearsOnMatchingToken() {
        var epoch = SupersessionEpoch()
        var slot = ClaimSlot<Int>()
        let stale = epoch.begin()
        let current = epoch.begin()
        _ = slot.install(1, ownedBy: current)

        XCTAssertFalse(slot.clearIfOwned(by: stale))
        XCTAssertEqual(slot.peekIfOwned(by: current), 1)

        XCTAssertTrue(slot.clearIfOwned(by: current))
        XCTAssertNil(slot.peekIfOwned(by: current))
    }

    func testClearIfOwnedOnEmptySlotReturnsFalse() {
        let epoch = SupersessionEpoch()
        var slot = ClaimSlot<Int>()
        XCTAssertFalse(slot.clearIfOwned(by: epoch.snapshot()))
    }
}

extension SupersessionEpoch {
    /// Test-only backdoor for exercising wraparound behavior without looping
    /// `begin()` `UInt64.max` times. Delegates to the module-internal
    /// `init(testRawValue:)`, reachable here via `@testable import`.
    fileprivate mutating func forceCurrent(rawValue: UInt64) {
        self = SupersessionEpoch(testRawValue: rawValue)
    }
}

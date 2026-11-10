import XCTest
@testable import TranscriptedCore

/// Pure authority/hold contracts. Marker objects carry identity only; these
/// tests never construct Audio, a capture backend, a device or a subscriber.
final class SystemAudioObservationOwnershipTests: XCTestCase {
    func testNoBindingExistsUntilASessionBegins() throws {
        let owner = SystemAudioObservationOwnership()
        let markers = ObservationOwnershipMarkers()
        defer { withExtendedLifetime(markers) {} }
        XCTAssertFalse(owner.isHolding)
        XCTAssertNil(owner.bind(generation: 0, captureID: markers.firstID))
        XCTAssertNil(owner.bind(generation: 7, captureID: markers.firstID))
        XCTAssertTrue(owner.beginSession(generation: 0))
        let token = try XCTUnwrap(owner.bind(generation: 0, captureID: markers.firstID))
        XCTAssertEqual(token.generation, 0)
        XCTAssertEqual(token.captureID, markers.firstID)
        XCTAssertTrue(owner.owns(token))
        XCTAssertFalse(owner.isHolding)
    }

    func testNewSessionRevokesOldEventsBeforeTheyCanChangeTheNewHold() throws {
        let owner = SystemAudioObservationOwnership()
        let markers = ObservationOwnershipMarkers()
        defer { withExtendedLifetime(markers) {} }
        XCTAssertTrue(owner.beginSession(generation: 10))
        let old = try XCTUnwrap(owner.bind(generation: 10, captureID: markers.firstID))
        XCTAssertTrue(owner.beginRecovery(old))
        XCTAssertTrue(owner.isHolding)

        XCTAssertTrue(owner.beginSession(generation: 11))
        XCTAssertFalse(owner.owns(old))
        XCTAssertFalse(owner.isHolding, "a new recording cannot inherit an old recovery hold")
        XCTAssertFalse(owner.beginRecovery(old))
        XCTAssertFalse(owner.endRecovery(old))
        XCTAssertFalse(owner.isHolding)
        let current = try XCTUnwrap(owner.bind(generation: 11, captureID: markers.secondID))
        XCTAssertTrue(owner.beginRecovery(current))
        XCTAssertTrue(owner.isHolding)
        XCTAssertFalse(owner.beginRecovery(old))
        XCTAssertFalse(owner.endRecovery(old), "an old abandoned/gap event cannot release a successor hold")
        XCTAssertTrue(owner.isHolding)
        XCTAssertTrue(owner.owns(current))
        XCTAssertTrue(owner.endRecovery(current))
        XCTAssertFalse(owner.isHolding, "old begin must not leave an extra hold behind the successor's balanced end")
    }

    func testSameGenerationBackendRebindRevokesAuthorityAndResetsItsHold() throws {
        let owner = SystemAudioObservationOwnership()
        let markers = ObservationOwnershipMarkers()
        defer { withExtendedLifetime(markers) {} }
        XCTAssertTrue(owner.beginSession(generation: 20))
        let old = try XCTUnwrap(owner.bind(generation: 20, captureID: markers.firstID))
        XCTAssertTrue(owner.beginRecovery(old))
        let current = try XCTUnwrap(owner.bind(generation: 20, captureID: markers.secondID))
        XCTAssertEqual(old.generation, current.generation)
        XCTAssertNotEqual(old.captureID, current.captureID)
        XCTAssertFalse(owner.owns(old))
        XCTAssertTrue(owner.owns(current))
        XCTAssertFalse(owner.isHolding)
        XCTAssertFalse(owner.beginRecovery(old))
        XCTAssertFalse(owner.endRecovery(old))
        XCTAssertFalse(owner.isHolding)
        XCTAssertTrue(owner.beginRecovery(current))
        XCTAssertFalse(owner.endRecovery(old))
        XCTAssertTrue(owner.isHolding)
        XCTAssertTrue(owner.endRecovery(current))
        XCTAssertFalse(owner.isHolding)
    }

    func testRebindingTheSameObjectInTheSameGenerationStillRevokesTheEarlierToken() throws {
        let owner = SystemAudioObservationOwnership()
        let markers = ObservationOwnershipMarkers()
        defer { withExtendedLifetime(markers) {} }
        XCTAssertTrue(owner.beginSession(generation: 30))
        let old = try XCTUnwrap(owner.bind(generation: 30, captureID: markers.firstID))
        XCTAssertTrue(owner.beginRecovery(old))
        let rebound = try XCTUnwrap(owner.bind(generation: 30, captureID: markers.firstID))
        XCTAssertEqual(old.generation, rebound.generation)
        XCTAssertEqual(old.captureID, rebound.captureID)
        XCTAssertNotEqual(old, rebound, "binding revision is authority even when the object identity is reused")
        XCTAssertFalse(owner.owns(old))
        XCTAssertTrue(owner.owns(rebound))
        XCTAssertFalse(owner.isHolding)
        XCTAssertTrue(owner.beginRecovery(rebound))
        XCTAssertFalse(owner.beginRecovery(old))
        XCTAssertFalse(owner.endRecovery(old))
        XCTAssertTrue(owner.isHolding)
        XCTAssertTrue(owner.endRecovery(rebound))
        XCTAssertFalse(owner.isHolding)
    }

    func testStaleSessionAndMismatchedBindsDoNotDisturbCurrentAuthorityOrHold() throws {
        let owner = SystemAudioObservationOwnership()
        let markers = ObservationOwnershipMarkers()
        defer { withExtendedLifetime(markers) {} }
        XCTAssertTrue(owner.beginSession(generation: 40))
        let current = try XCTUnwrap(owner.bind(generation: 40, captureID: markers.firstID))
        XCTAssertTrue(owner.beginRecovery(current))
        XCTAssertFalse(owner.beginSession(generation: 39))
        XCTAssertTrue(owner.owns(current))
        XCTAssertTrue(owner.isHolding)
        XCTAssertNil(owner.bind(generation: 39, captureID: markers.secondID))
        XCTAssertTrue(owner.owns(current))
        XCTAssertTrue(owner.isHolding)
        XCTAssertNil(owner.bind(generation: 41, captureID: markers.secondID))
        XCTAssertTrue(owner.owns(current))
        XCTAssertTrue(owner.isHolding)
        XCTAssertTrue(owner.endRecovery(current))
        XCTAssertFalse(owner.isHolding)
    }

    func testEqualSessionBeginIsIdempotentAndPreservesOutstandingRecoveryDepth() throws {
        let owner = SystemAudioObservationOwnership()
        let markers = ObservationOwnershipMarkers()
        defer { withExtendedLifetime(markers) {} }
        XCTAssertTrue(owner.beginSession(generation: 50))
        let current = try XCTUnwrap(owner.bind(generation: 50, captureID: markers.firstID))
        XCTAssertTrue(owner.beginRecovery(current))
        XCTAssertTrue(owner.beginRecovery(current))
        XCTAssertTrue(owner.beginSession(generation: 50))
        XCTAssertTrue(owner.owns(current))
        XCTAssertTrue(owner.isHolding)
        XCTAssertTrue(owner.endRecovery(current))
        XCTAssertTrue(owner.isHolding, "equal session begin must not flatten a nested recovery hold")
        XCTAssertTrue(owner.beginSession(generation: 50))
        XCTAssertTrue(owner.endRecovery(current))
        XCTAssertFalse(owner.isHolding)
        XCTAssertTrue(owner.owns(current))
    }

    func testCurrentRecoveryIsBalancedAndAnExtraEndCannotUnderflow() throws {
        let owner = SystemAudioObservationOwnership()
        let markers = ObservationOwnershipMarkers()
        defer { withExtendedLifetime(markers) {} }
        XCTAssertTrue(owner.beginSession(generation: 60))
        let current = try XCTUnwrap(owner.bind(generation: 60, captureID: markers.firstID))
        XCTAssertFalse(owner.endRecovery(current))
        XCTAssertFalse(owner.isHolding)
        XCTAssertTrue(owner.beginRecovery(current))
        XCTAssertTrue(owner.beginRecovery(current))
        XCTAssertTrue(owner.endRecovery(current))
        XCTAssertTrue(owner.isHolding)
        XCTAssertTrue(owner.endRecovery(current))
        XCTAssertFalse(owner.isHolding)
        XCTAssertFalse(owner.endRecovery(current))
        XCTAssertFalse(owner.isHolding)
        XCTAssertTrue(owner.beginRecovery(current), "a balanced token remains reusable for the next recovery")
        XCTAssertTrue(owner.isHolding)
        XCTAssertTrue(owner.endRecovery(current))
        XCTAssertFalse(owner.isHolding)
    }

    func testAMicOnlySessionBoundaryStaysUnboundAndIgnoresOldRecoveryEvents() throws {
        let owner = SystemAudioObservationOwnership()
        let markers = ObservationOwnershipMarkers()
        defer { withExtendedLifetime(markers) {} }
        XCTAssertTrue(owner.beginSession(generation: 70))
        let old = try XCTUnwrap(owner.bind(generation: 70, captureID: markers.firstID))
        XCTAssertTrue(owner.beginRecovery(old))
        // A mic-only successor starts a session but binds no system producer.
        XCTAssertTrue(owner.beginSession(generation: 71))
        XCTAssertFalse(owner.owns(old))
        XCTAssertFalse(owner.isHolding)
        XCTAssertFalse(owner.beginRecovery(old))
        XCTAssertFalse(owner.endRecovery(old))
        XCTAssertTrue(owner.beginSession(generation: 71))
        XCTAssertNil(owner.bind(generation: 70, captureID: markers.firstID))
        XCTAssertFalse(owner.isHolding)
        XCTAssertFalse(owner.owns(old))
    }
}

private final class ObservationOwnershipMarker {}

private final class ObservationOwnershipMarkers {
    private let first = ObservationOwnershipMarker()
    private let second = ObservationOwnershipMarker()
    var firstID: ObjectIdentifier { ObjectIdentifier(first) }
    var secondID: ObjectIdentifier { ObjectIdentifier(second) }
}

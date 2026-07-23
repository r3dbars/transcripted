// ParakeetAudioObserverOwnershipTests.swift
//
// Deterministic observer-binding interleavings for cancelled and overlapping
// audio-engine rebuilds.

import Foundation

func testParakeetAudioObserverOwnership() {
    runSuite("Parakeet stale rebuild restores only the same engine observer") {
        let engine = NSObject()
        let replacementEngine = NSObject()
        let rebuildOwner = ParakeetAudioGraphOwnerToken(generation: 27, engine: engine)

        assertTrue(
            rebuildOwner.matchesEngine(engine),
            "generation-only cancellation should retain the same engine identity for observer restoration"
        )
        assertFalse(
            rebuildOwner.matchesEngine(replacementEngine),
            "a replacement engine must own its own configuration observer"
        )
    }

    runSuite("Parakeet overlapping rebuild binds the final observer to the live engine") {
        let retiredEngine = NSObject()
        let replacementEngine = NSObject()
        let staleOwner = ParakeetAudioGraphOwnerToken(generation: 31, engine: retiredEngine)
        var observer = ParakeetAudioObserverBindingTestState()

        observer.remove()
        observer.remove()
        if staleOwner.matchesEngine(retiredEngine) {
            observer.installIfNeeded(on: retiredEngine)
        }
        assertTrue(observer.isObserving(retiredEngine), "the stale continuation should restore its current engine")

        observer.remove()
        observer.installIfNeeded(on: replacementEngine)
        assertFalse(observer.isObserving(retiredEngine), "successful replacement must remove the stale observer")
        assertTrue(observer.isObserving(replacementEngine), "the final observer must follow the live engine")
    }
}

private struct ParakeetAudioObserverBindingTestState {
    private var engineIdentity: ObjectIdentifier?

    mutating func remove() {
        engineIdentity = nil
    }

    mutating func installIfNeeded(on engine: AnyObject) {
        guard engineIdentity == nil else { return }
        engineIdentity = ObjectIdentifier(engine)
    }

    func isObserving(_ engine: AnyObject) -> Bool {
        engineIdentity == ObjectIdentifier(engine)
    }
}

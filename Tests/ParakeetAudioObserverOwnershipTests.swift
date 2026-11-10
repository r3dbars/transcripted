// ParakeetAudioObserverOwnershipTests.swift
//
// Engine-identity policy for observer restoration after a cancelled rebuild.

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
}

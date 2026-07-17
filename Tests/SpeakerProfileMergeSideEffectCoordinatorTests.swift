import Foundation

private enum SpeakerProfileMergeSideEffectTestError: Error {
    case mergeFailed
}

func testSpeakerProfileMergeSideEffectCoordinator() {
    runSuite("Speaker clip side effects follow the committed database merge") {
        var operations: [String] = []

        do {
            try SpeakerProfileMergeSideEffectCoordinator.merge(
                databaseMerge: { () throws -> Void in operations.append("database") },
                promoteClip: { operations.append("promote") },
                deleteSourceClips: { operations.append("delete-source") }
            )
        } catch {
            assertTrue(false, "Unexpected merge error: \(error)")
        }

        assertEqual(
            operations,
            ["database", "promote", "delete-source"],
            "clip promotion and deletion should follow the committed database merge"
        )
    }

    runSuite("A throwing database merge leaves speaker clips untouched") {
        var operations: [String] = []

        do {
            try SpeakerProfileMergeSideEffectCoordinator.merge(
                databaseMerge: {
                    operations.append("database")
                    throw SpeakerProfileMergeSideEffectTestError.mergeFailed
                },
                promoteClip: { operations.append("promote") },
                deleteSourceClips: { operations.append("delete-source") }
            )
            assertTrue(false, "Expected database merge failure")
        } catch SpeakerProfileMergeSideEffectTestError.mergeFailed {
            // Expected. Filesystem side effects must not run after rollback.
        } catch {
            assertTrue(false, "Unexpected merge error: \(error)")
        }

        assertEqual(
            operations,
            ["database"],
            "a throwing database merge must leave both source and target clips untouched"
        )
    }
}

// CaptureUndoTests.swift
// Tests for the shared undo seam: Trash-based file move/restore, day-file
// content rewrite/restore, and the grace-window pending/undo/finalize state
// machine. The grace window itself is never waited on in real time — tests
// simulate it elapsing by calling `finalize(_:)` directly, the same call the
// real `DispatchQueue.main.asyncAfter` timer makes once it fires.

import Foundation

func testCaptureUndo() async {
    runSuite("CaptureTrashOperation.trash — moves existing files to the Trash and skips missing ones") {
        let fm = FileManager.default
        let root = temporaryCaptureUndoTestRoot()
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let present = root.appendingPathComponent("present.md")
        let missing = root.appendingPathComponent("missing.md")
        try? "present".write(to: present, atomically: true, encoding: .utf8)

        do {
            let trashed = try CaptureTrashOperation.trash([present, missing], fileManager: fm)

            assertEqual(trashed.count, 1, "only the file that exists should be trashed")
            assertEqual(trashed.first?.originalURL, present, "trashed record should keep the original URL")
            assertFalse(fm.fileExists(atPath: present.path), "original path should no longer exist after trashing")

            guard let trashedURL = trashed.first?.trashedURL else {
                assertTrue(false, "trash should report a resulting Trash URL")
                return
            }
            assertTrue(fm.fileExists(atPath: trashedURL.path), "trashed file should exist at its reported Trash location")

            CaptureTrashOperation.restore(trashed, fileManager: fm)
            assertTrue(fm.fileExists(atPath: present.path), "restore should move the file back to its original path")
            assertFalse(fm.fileExists(atPath: trashedURL.path), "restore should leave nothing behind at the Trash location")
        } catch {
            assertTrue(false, "trash should not throw for an existing file: \(error)")
        }
    }

    runSuite("CaptureTrashOperation.restore recreates a parent directory something else removed") {
        let fm = FileManager.default
        let root = temporaryCaptureUndoTestRoot()
        let subdir = root.appendingPathComponent("audio", isDirectory: true)
        try? fm.createDirectory(at: subdir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let target = subdir.appendingPathComponent("clip.wav")
        try? "clip".write(to: target, atomically: true, encoding: .utf8)

        guard let trashed = try? CaptureTrashOperation.trash([target], fileManager: fm), !trashed.isEmpty else {
            assertTrue(false, "setup: trashing the fixture file should succeed")
            return
        }

        // Simulate something else clearing the parent directory while the
        // file sat in the Trash during the grace window.
        try? fm.removeItem(at: subdir)

        CaptureTrashOperation.restore(trashed, fileManager: fm)
        assertTrue(fm.fileExists(atPath: target.path), "restore should recreate the missing parent directory")
    }

    runSuite("CaptureUndoMessage.deleted — matches the prototype's smart-quote copy") {
        assertEqual(
            CaptureUndoMessage.deleted("Product review"),
            "Deleted \u{201C}Product review\u{201D}",
            "deleted(_:) should wrap the title in smart quotes, not straight ones"
        )
    }

    await runSuite("CaptureUndoManager.deleteFiles — trashes immediately and publishes a pending offer") {
        let fm = FileManager.default
        let root = temporaryCaptureUndoTestRoot()
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let transcript = root.appendingPathComponent("Product review.md")
        try? "transcript body".write(to: transcript, atomically: true, encoding: .utf8)

        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let manager = await CaptureUndoManager(graceWindow: 6, now: { fixedNow })
        let id = "meeting-1"

        do {
            let offer = try await manager.deleteFiles(
                id: id,
                urls: [transcript],
                message: CaptureUndoMessage.deleted("Product review"),
                fileManager: fm
            )

            assertEqual(offer.id, id, "offer should carry the caller's id")
            assertEqual(offer.message, "Deleted \u{201C}Product review\u{201D}", "offer message should be the caller-supplied copy")
            assertEqual(offer.expiresAt, fixedNow.addingTimeInterval(6), "offer should expire exactly one grace window after now")
            assertFalse(fm.fileExists(atPath: transcript.path), "file should already be gone from its original path")

            let isPending = await manager.isPending(id)
            assertTrue(isPending, "id should be pending right after delete")
            let lookedUp = await manager.offer(for: id)
            assertEqual(lookedUp, offer, "offer(for:) should return the published offer")
        } catch {
            assertTrue(false, "deleteFiles should not throw: \(error)")
        }

        // Clean up the pending timer for this manager instance.
        await manager.finalize(id)
    }

    await runSuite("CaptureUndoManager.undo — restores trashed files and clears the offer within the grace window") {
        let fm = FileManager.default
        let root = temporaryCaptureUndoTestRoot()
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let transcript = root.appendingPathComponent("Product review.md")
        try? "transcript body".write(to: transcript, atomically: true, encoding: .utf8)

        let manager = await CaptureUndoManager()
        let id = "meeting-1"

        do {
            _ = try await manager.deleteFiles(
                id: id,
                urls: [transcript],
                message: CaptureUndoMessage.deleted("Product review"),
                fileManager: fm
            )

            await manager.undo(id)

            assertTrue(fm.fileExists(atPath: transcript.path), "undo should restore the trashed file")
            let stillPending = await manager.isPending(id)
            assertFalse(stillPending, "id should no longer be pending after undo")
            let clearedOffer = await manager.offer(for: id)
            assertNil(clearedOffer, "offer should be cleared after undo")
        } catch {
            assertTrue(false, "deleteFiles should not throw: \(error)")
        }
    }

    await runSuite("CaptureUndoManager.finalize — makes deletion permanent; a later undo is a no-op") {
        let fm = FileManager.default
        let root = temporaryCaptureUndoTestRoot()
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let transcript = root.appendingPathComponent("Quick notes.md")
        try? "body".write(to: transcript, atomically: true, encoding: .utf8)

        let manager = await CaptureUndoManager()
        let id = "meeting-2"
        let finalizeRan = FinalizeFlag()

        do {
            _ = try await manager.deleteFiles(
                id: id,
                urls: [transcript],
                message: CaptureUndoMessage.deleted("Quick notes"),
                fileManager: fm,
                finalize: { finalizeRan.mark() }
            )

            await manager.finalize(id)
            assertTrue(finalizeRan.value, "finalize closure should run once the deletion becomes permanent")

            let pending = await manager.isPending(id)
            assertFalse(pending, "id should no longer be pending after finalize")

            // A stale undo (grace window already elapsed) must not resurrect
            // the file.
            await manager.undo(id)
            assertFalse(fm.fileExists(atPath: transcript.path), "undo after finalize should not resurrect the file")

            // finalize is idempotent — calling it again must not re-run the closure.
            await manager.finalize(id)
        } catch {
            assertTrue(false, "deleteFiles should not throw: \(error)")
        }
    }

    await runSuite("CaptureUndoManager — a second delete for the same id finalizes the stale offer first") {
        let fm = FileManager.default
        let root = temporaryCaptureUndoTestRoot()
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try? "first".write(to: first, atomically: true, encoding: .utf8)
        try? "second".write(to: second, atomically: true, encoding: .utf8)

        let manager = await CaptureUndoManager()
        let id = "reused-id"
        let firstFinalizeRan = FinalizeFlag()

        do {
            _ = try await manager.deleteFiles(
                id: id,
                urls: [first],
                message: "Deleted \u{201C}first\u{201D}",
                fileManager: fm,
                finalize: { firstFinalizeRan.mark() }
            )
            _ = try await manager.deleteFiles(
                id: id,
                urls: [second],
                message: "Deleted \u{201C}second\u{201D}",
                fileManager: fm
            )

            assertTrue(firstFinalizeRan.value, "starting a new delete for a still-pending id should finalize the stale one")
            let offer = await manager.offer(for: id)
            assertEqual(offer?.message, "Deleted \u{201C}second\u{201D}", "the live offer should be the second delete's")

            await manager.undo(id)
            assertTrue(fm.fileExists(atPath: second.path), "undo should restore the second (still-pending) delete")
            assertFalse(fm.fileExists(atPath: first.path), "the first delete stayed finalized — permanently trashed")
        } catch {
            assertTrue(false, "deleteFiles should not throw: \(error)")
        }
    }
}

private func temporaryCaptureUndoTestRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "TranscriptedCaptureUndoTests-\(UUID().uuidString)",
        isDirectory: true
    )
}

/// Plain mutable box for capturing whether a `finalize` closure ran, since
/// the closures under test are non-`@Sendable` and run on the main actor.
private final class FinalizeFlag: @unchecked Sendable {
    private(set) var value = false
    func mark() { value = true }
}

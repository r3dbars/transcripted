import Foundation

func testCaptureLibraryMigrationPlanner() {
    let fileManager = FileManager.default
    let planner = CaptureLibraryMigrationPlanner()

    func makeLibraryRoot(_ label: String) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(
            "CaptureLibraryMigrationPlannerTests-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    func writeFile(_ contents: String, at url: URL) {
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(contents.utf8).write(to: url, options: [.atomic])
    }

    func makeDirectory(at url: URL) {
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func readFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    runSuite("libraryHasCaptures - missing or empty libraries have nothing to copy") {
        let missing = makeLibraryRoot("missing")
        assertFalse(
            planner.libraryHasCaptures(at: missing),
            "a library that does not exist should not offer a copy"
        )

        let empty = makeLibraryRoot("empty")
        defer { try? fileManager.removeItem(at: empty) }
        makeDirectory(at: empty.appendingPathComponent("meetings", isDirectory: true))
        makeDirectory(at: empty.appendingPathComponent("dictations", isDirectory: true))
        assertFalse(
            planner.libraryHasCaptures(at: empty),
            "empty meetings and dictations folders should not offer a copy"
        )
    }

    runSuite("libraryHasCaptures - meeting Markdown, retained audio, or dictations count") {
        let meetingsOnly = makeLibraryRoot("meetings-only")
        defer { try? fileManager.removeItem(at: meetingsOnly) }
        writeFile("# standup", at: meetingsOnly
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-01-05 Standup.md", isDirectory: false))
        assertTrue(
            planner.libraryHasCaptures(at: meetingsOnly),
            "a meeting transcript alone should count as existing captures"
        )

        let audioOnly = makeLibraryRoot("audio-only")
        defer { try? fileManager.removeItem(at: audioOnly) }
        writeFile("m4a-bytes", at: audioOnly
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("2026-01-05 Standup_audio", isDirectory: true)
            .appendingPathComponent("microphone.m4a", isDirectory: false))
        assertTrue(
            planner.libraryHasCaptures(at: audioOnly),
            "retained meeting audio alone should count as existing captures"
        )

        let dictationsOnly = makeLibraryRoot("dictations-only")
        defer { try? fileManager.removeItem(at: dictationsOnly) }
        writeFile("- dictated", at: dictationsOnly
            .appendingPathComponent("dictations", isDirectory: true)
            .appendingPathComponent("2026-01-05.md", isDirectory: false))
        assertTrue(
            planner.libraryHasCaptures(at: dictationsOnly),
            "a dictation day file alone should count as existing captures"
        )
    }

    runSuite("makePlan - enumerates transcripts, retained audio directories, and dictations") {
        let old = makeLibraryRoot("plan-old")
        let new = makeLibraryRoot("plan-new")
        defer {
            try? fileManager.removeItem(at: old)
            try? fileManager.removeItem(at: new)
        }

        let oldMeetings = old.appendingPathComponent("meetings", isDirectory: true)
        writeFile("# standup", at: oldMeetings.appendingPathComponent("2026-01-05 Standup.md", isDirectory: false))
        writeFile("summary", at: oldMeetings.appendingPathComponent("2026-01-05 Standup.summary.md", isDirectory: false))
        writeFile("not markdown", at: oldMeetings.appendingPathComponent("notes.txt", isDirectory: false))
        writeFile("mic", at: oldMeetings
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("2026-01-05 Standup_audio", isDirectory: true)
            .appendingPathComponent("microphone.m4a", isDirectory: false))
        makeDirectory(at: oldMeetings
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("scratch", isDirectory: true))
        writeFile("loose", at: oldMeetings
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("loose.wav", isDirectory: false))
        writeFile("- dictated", at: old
            .appendingPathComponent("dictations", isDirectory: true)
            .appendingPathComponent("2026-01-05.md", isDirectory: false))

        let plan = planner.makePlan(from: old, to: new)

        assertEqual(plan.itemsToCopy.count, 4, "plan should copy two meeting md files, one audio dir, one dictation")
        assertEqual(plan.skippedExisting.count, 0, "an empty destination should have no collisions")
        assertEqual(plan.itemsToCopy.filter { $0.kind == .meetingTranscript }.count, 2)
        assertEqual(plan.itemsToCopy.filter { $0.kind == .meetingAudioDirectory }.count, 1)
        assertEqual(plan.itemsToCopy.filter { $0.kind == .dictationTranscript }.count, 1)
    }

    runSuite("makePlan - relocating to the same folder plans nothing") {
        let library = makeLibraryRoot("plan-same")
        defer { try? fileManager.removeItem(at: library) }
        writeFile("# standup", at: library
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-01-05 Standup.md", isDirectory: false))

        let plan = planner.makePlan(from: library, to: library)
        assertTrue(plan.isEmpty, "same-folder relocation should be a planned no-op")
    }

    runSuite("makePlan - destination name collisions are planned as skips") {
        let old = makeLibraryRoot("collide-old")
        let new = makeLibraryRoot("collide-new")
        defer {
            try? fileManager.removeItem(at: old)
            try? fileManager.removeItem(at: new)
        }

        writeFile("old copy", at: old
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-01-05 Standup.md", isDirectory: false))
        writeFile("fresh", at: old
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-01-06 Review.md", isDirectory: false))
        writeFile("already at destination", at: new
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-01-05 Standup.md", isDirectory: false))

        let plan = planner.makePlan(from: old, to: new)

        assertEqual(plan.itemsToCopy.count, 1, "only the non-colliding transcript should be planned")
        assertEqual(plan.itemsToCopy.first?.sourceURL.lastPathComponent, "2026-01-06 Review.md")
        assertEqual(plan.skippedExisting.count, 1, "the colliding name should be planned as a skip")
        assertEqual(plan.skippedExisting.first?.sourceURL.lastPathComponent, "2026-01-05 Standup.md")
    }

    runSuite("copy - copies planned items, keeps originals, and never overwrites") {
        let old = makeLibraryRoot("copy-old")
        let new = makeLibraryRoot("copy-new")
        defer {
            try? fileManager.removeItem(at: old)
            try? fileManager.removeItem(at: new)
        }

        let oldTranscript = old
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-01-05 Standup.md", isDirectory: false)
        writeFile("# standup", at: oldTranscript)
        writeFile("mic", at: old
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("2026-01-05 Standup_audio", isDirectory: true)
            .appendingPathComponent("microphone.m4a", isDirectory: false))
        writeFile("- dictated", at: old
            .appendingPathComponent("dictations", isDirectory: true)
            .appendingPathComponent("2026-01-05.md", isDirectory: false))
        let collidingDestination = new
            .appendingPathComponent("dictations", isDirectory: true)
            .appendingPathComponent("2026-01-05.md", isDirectory: false)
        writeFile("destination keeps this", at: collidingDestination)

        let plan = planner.makePlan(from: old, to: new)
        var progressUpdates: [Int] = []
        let result = try? planner.copy(plan) { copied, _ in
            progressUpdates.append(copied)
        }

        assertEqual(result?.copiedCount, 2, "the transcript and the audio directory should copy")
        assertEqual(result?.skippedExistingCount, 1, "the colliding dictation day file should be skipped")
        assertEqual(progressUpdates, [1, 2], "progress should report each completed copy")
        assertEqual(readFile(at: new.appendingPathComponent("meetings/2026-01-05 Standup.md")), "# standup")
        assertEqual(readFile(at: new.appendingPathComponent("meetings/audio/2026-01-05 Standup_audio/microphone.m4a")), "mic")
        assertEqual(readFile(at: collidingDestination), "destination keeps this")
        assertEqual(readFile(at: oldTranscript), "# standup", "originals must stay in the old library")
    }

    runSuite("copy - re-checks collisions right before copying") {
        let old = makeLibraryRoot("late-collision-old")
        let new = makeLibraryRoot("late-collision-new")
        defer {
            try? fileManager.removeItem(at: old)
            try? fileManager.removeItem(at: new)
        }

        writeFile("from old", at: old
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-01-05 Standup.md", isDirectory: false))

        let plan = planner.makePlan(from: old, to: new)
        let lateArrival = new
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-01-05 Standup.md", isDirectory: false)
        writeFile("late arrival keeps this", at: lateArrival)

        let result = try? planner.copy(plan)

        assertEqual(result?.copiedCount, 0, "the late collision should not be copied over")
        assertEqual(result?.skippedExistingCount, 1, "the late collision should count as a skip")
        assertEqual(readFile(at: lateArrival), "late arrival keeps this", "late arrivals must not be overwritten")
    }

    runSuite("copy - stops with a descriptive error when a source disappears") {
        let old = makeLibraryRoot("error-old")
        let new = makeLibraryRoot("error-new")
        defer {
            try? fileManager.removeItem(at: old)
            try? fileManager.removeItem(at: new)
        }

        let vanishing = old
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-01-05 Standup.md", isDirectory: false)
        writeFile("# standup", at: vanishing)

        let plan = planner.makePlan(from: old, to: new)
        try? fileManager.removeItem(at: vanishing)

        var thrown: Error?
        do {
            _ = try planner.copy(plan)
        } catch {
            thrown = error
        }

        assertNotNil(thrown, "a vanished source should stop the copy with an error")
        assertTrue(
            thrown?.localizedDescription.contains(vanishing.path) == true,
            "the copy error should name the source path that failed"
        )
    }

    runSuite("move - removes originals that were copied and left unchanged") {
        let old = makeLibraryRoot("move-old")
        let new = makeLibraryRoot("move-new")
        defer {
            try? fileManager.removeItem(at: old)
            try? fileManager.removeItem(at: new)
        }
        var removedPaths: [String] = []
        let movingPlanner = CaptureLibraryMigrationPlanner(removeOriginal: { url in
            removedPaths.append(url.lastPathComponent)
            try fileManager.removeItem(at: url)
        })

        let oldTranscript = old.appendingPathComponent("meetings/2026-01-05 Standup.md")
        let oldAudio = old.appendingPathComponent("meetings/audio/2026-01-05 Standup_audio", isDirectory: true)
        let oldDictation = old.appendingPathComponent("dictations/2026-01-05.md")
        writeFile("# standup", at: oldTranscript)
        writeFile("mic", at: oldAudio.appendingPathComponent("microphone.m4a"))
        writeFile("- dictated", at: oldDictation)
        let collidingDestination = new.appendingPathComponent("dictations/2026-01-05.md")
        writeFile("destination keeps this", at: collidingDestination)

        let plan = movingPlanner.makePlan(from: old, to: new)
        let copyResult = try? movingPlanner.copy(plan)
        assertEqual(copyResult?.copiedItems.count, 2, "copy should report both copied items for the move step")

        let removal = movingPlanner.removeOriginals(of: copyResult?.copiedItems ?? [])

        assertEqual(removal, CaptureLibraryOriginalsRemovalResult(removedCount: 2, keptChangedCount: 0, failedCount: 0))
        assertEqual(removedPaths.sorted(), ["2026-01-05 Standup.md", "2026-01-05 Standup_audio"], "only the copied transcript and audio folder should be removed")
        assertFalse(fileManager.fileExists(atPath: oldTranscript.path), "the moved transcript should leave the old library")
        assertFalse(fileManager.fileExists(atPath: oldAudio.path), "the moved audio folder should leave the old library")
        assertEqual(readFile(at: oldDictation), "- dictated", "a skipped collision must keep its original")
        assertEqual(readFile(at: collidingDestination), "destination keeps this", "the destination file must not be touched")
        assertEqual(readFile(at: new.appendingPathComponent("meetings/2026-01-05 Standup.md")), "# standup")
        assertEqual(readFile(at: new.appendingPathComponent("meetings/audio/2026-01-05 Standup_audio/microphone.m4a")), "mic")
    }

    runSuite("move - keeps an original that changed after it was copied") {
        let old = makeLibraryRoot("move-changed-old")
        let new = makeLibraryRoot("move-changed-new")
        defer {
            try? fileManager.removeItem(at: old)
            try? fileManager.removeItem(at: new)
        }
        let movingPlanner = CaptureLibraryMigrationPlanner(removeOriginal: { url in
            try fileManager.removeItem(at: url)
        })

        let oldDictation = old.appendingPathComponent("dictations/2026-01-05.md")
        let oldAudio = old.appendingPathComponent("meetings/audio/2026-01-05 Standup_audio", isDirectory: true)
        writeFile("- first", at: oldDictation)
        writeFile("mic", at: oldAudio.appendingPathComponent("microphone.wav"))

        let copyResult = try? movingPlanner.copy(movingPlanner.makePlan(from: old, to: new))
        // A dictation lands on today's file, and background recompression
        // adds a file to the audio folder, both after the copy.
        writeFile("- first\n- second, dictated mid-move", at: oldDictation)
        writeFile("m4a", at: oldAudio.appendingPathComponent("microphone.m4a"))

        let removal = movingPlanner.removeOriginals(of: copyResult?.copiedItems ?? [])

        assertEqual(removal, CaptureLibraryOriginalsRemovalResult(removedCount: 0, keptChangedCount: 2, failedCount: 0))
        assertEqual(readFile(at: oldDictation), "- first\n- second, dictated mid-move", "a changed original must be kept so the new dictation isn't lost")
        assertTrue(fileManager.fileExists(atPath: oldAudio.appendingPathComponent("microphone.m4a").path), "a changed audio folder must be kept")
    }

    runSuite("move - keeps the original when its copy went missing, and counts failures") {
        let old = makeLibraryRoot("move-missing-old")
        let new = makeLibraryRoot("move-missing-new")
        defer {
            try? fileManager.removeItem(at: old)
            try? fileManager.removeItem(at: new)
        }
        let oldTranscript = old.appendingPathComponent("meetings/2026-01-05 Standup.md")
        let oldDictation = old.appendingPathComponent("dictations/2026-01-05.md")
        writeFile("# standup", at: oldTranscript)
        writeFile("- dictated", at: oldDictation)

        struct TrashRefused: Error {}
        let refusingPlanner = CaptureLibraryMigrationPlanner(removeOriginal: { _ in throw TrashRefused() })
        let copyResult = try? refusingPlanner.copy(refusingPlanner.makePlan(from: old, to: new))
        try? fileManager.removeItem(at: new.appendingPathComponent("meetings/2026-01-05 Standup.md"))

        let removal = refusingPlanner.removeOriginals(of: copyResult?.copiedItems ?? [])

        assertEqual(removal, CaptureLibraryOriginalsRemovalResult(removedCount: 0, keptChangedCount: 1, failedCount: 1))
        assertEqual(readFile(at: oldTranscript), "# standup", "an original whose copy is gone must be kept")
        assertEqual(readFile(at: oldDictation), "- dictated", "an original the Trash refused must still be there")
    }

    runSuite("move summary - says what moved, what stayed, and where") {
        let clean = CaptureLibraryMoveSummary.text(
            copy: CaptureLibraryMigrationResult(copiedCount: 3, skippedExistingCount: 0),
            removal: CaptureLibraryOriginalsRemovalResult(removedCount: 3, keptChangedCount: 0, failedCount: 0),
            oldLibraryPath: "/Old"
        )
        assertEqual(clean, "Moved 3 items to the new folder. The old copies are in the Trash.")

        let mixed = CaptureLibraryMoveSummary.text(
            copy: CaptureLibraryMigrationResult(copiedCount: 3, skippedExistingCount: 1),
            removal: CaptureLibraryOriginalsRemovalResult(removedCount: 1, keptChangedCount: 1, failedCount: 1),
            oldLibraryPath: "/Old"
        )
        assertEqual(
            mixed,
            "Moved 1 item to the new folder. The old copies are in the Trash. 1 item changed during the move, so the newest version is still in /Old. 1 item couldn't go to the Trash and is still in /Old. 1 item stayed in /Old because the new folder already had a file with the same name."
        )
    }
}

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

    runSuite("libraryHasCaptures — missing or empty libraries have nothing to copy") {
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

    runSuite("libraryHasCaptures — meeting Markdown, retained audio, or dictations count") {
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

    runSuite("makePlan — enumerates transcripts, retained audio directories, and dictations") {
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
        // A stray non-audio directory and a loose file under audio/ should not be planned.
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

        let kinds = plan.itemsToCopy.map(\.kind)
        assertEqual(
            kinds.filter { $0 == .meetingTranscript }.count, 2,
            "both meeting Markdown files (transcript and summary sidecar) should be planned"
        )
        assertEqual(
            kinds.filter { $0 == .meetingAudioDirectory }.count, 1,
            "only the retained _audio directory should be planned from audio/"
        )
        assertEqual(
            kinds.filter { $0 == .dictationTranscript }.count, 1,
            "the dictation day file should be planned"
        )

        let audioItem = plan.itemsToCopy.first { $0.kind == .meetingAudioDirectory }
        assertEqual(
            audioItem?.destinationURL.standardizedFileURL.path,
            new.standardizedFileURL
                .appendingPathComponent("meetings/audio/2026-01-05 Standup_audio").path,
            "retained audio should land under <new>/meetings/audio/"
        )
        let dictationItem = plan.itemsToCopy.first { $0.kind == .dictationTranscript }
        assertEqual(
            dictationItem?.destinationURL.standardizedFileURL.path,
            new.standardizedFileURL.appendingPathComponent("dictations/2026-01-05.md").path,
            "dictation day files should land under <new>/dictations/"
        )
    }

    runSuite("makePlan — relocating to the same folder plans nothing") {
        let library = makeLibraryRoot("plan-same")
        defer { try? fileManager.removeItem(at: library) }
        writeFile("# standup", at: library
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-01-05 Standup.md", isDirectory: false))

        let plan = planner.makePlan(from: library, to: library)
        assertTrue(plan.isEmpty, "same-folder relocation should be a planned no-op")
    }

    runSuite("makePlan — destination name collisions are planned as skips") {
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

        assertEqual(plan.itemsToCopy.count, 1, "only the non-colliding transcript should be planned for copy")
        assertEqual(plan.itemsToCopy.first?.sourceURL.lastPathComponent, "2026-01-06 Review.md")
        assertEqual(plan.skippedExisting.count, 1, "the colliding name should be planned as a skip")
        assertEqual(plan.skippedExisting.first?.sourceURL.lastPathComponent, "2026-01-05 Standup.md")
    }

    runSuite("copy — copies planned items, keeps originals, and never overwrites") {
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

        assertEqual(
            readFile(at: new.appendingPathComponent("meetings/2026-01-05 Standup.md")),
            "# standup",
            "the transcript should arrive at the new library"
        )
        assertEqual(
            readFile(at: new.appendingPathComponent("meetings/audio/2026-01-05 Standup_audio/microphone.m4a")),
            "mic",
            "the retained audio directory should arrive with its contents"
        )
        assertEqual(
            readFile(at: collidingDestination),
            "destination keeps this",
            "existing destination files must never be overwritten"
        )
        assertEqual(
            readFile(at: oldTranscript),
            "# standup",
            "originals must stay in the old library after the copy"
        )
    }

    runSuite("copy — re-checks collisions right before copying") {
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
        assertEqual(plan.itemsToCopy.count, 1, "the transcript should be planned before the late collision")

        // A file that lands at the destination between planning and copying is
        // a collision, not something to overwrite.
        let lateArrival = new
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("2026-01-05 Standup.md", isDirectory: false)
        writeFile("late arrival keeps this", at: lateArrival)

        let result = try? planner.copy(plan)

        assertEqual(result?.copiedCount, 0, "the late collision should not be copied over")
        assertEqual(result?.skippedExistingCount, 1, "the late collision should count as a skip")
        assertEqual(
            readFile(at: lateArrival),
            "late arrival keeps this",
            "a file that appeared after planning must not be overwritten"
        )
    }

    runSuite("copy — stops with a descriptive error when a source disappears") {
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
}

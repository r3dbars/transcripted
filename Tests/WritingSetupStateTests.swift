import Foundation

// Behavioral coverage for when Writing runs (Sources/Writing/WritingSetupState.swift)
// and the storage meter's numbers (Sources/Writing/WritingStorageUsage.swift).

func testWritingSetupState() {
    runSuite("Writing runs once setup is done and a feature is on") {
        for save in [false, true] {
            for autocomplete in [false, true] {
                assertFalse(
                    WritingActivation.shouldRun(setupCompleted: false, saveMyWriting: save, autocomplete: autocomplete, debugEnabled: false),
                    "nothing runs before \"Turn on writing\" (save \(save), autocomplete \(autocomplete))"
                )
                assertEqual(
                    WritingActivation.shouldRun(setupCompleted: true, saveMyWriting: save, autocomplete: autocomplete, debugEnabled: false),
                    save || autocomplete,
                    "after setup it runs with at least one feature on (save \(save), autocomplete \(autocomplete))"
                )
            }
        }
        assertTrue(
            WritingActivation.shouldRun(setupCompleted: false, saveMyWriting: false, autocomplete: false, debugEnabled: true),
            "the development default still starts it"
        )
    }

    runSuite("Launch reaps an orphaned Writing helper once setup is done, whatever the switches say") {
        assertTrue(WritingActivation.reapsOrphanedHelperAtLaunch(setupCompleted: true))
        assertFalse(
            WritingActivation.reapsOrphanedHelperAtLaunch(setupCompleted: false),
            "before \"Turn on writing\" no helper was ever launched"
        )
    }

    runSuite("Save-only Writing watches no windows; the 1 Hz poll needs Autocomplete and Screen Memory") {
        for screenMemory in [false, true] {
            assertEqual(
                WritingFrontWindowWatch.plan(running: true, autocompleteActive: false, screenMemoryEnabled: screenMemory),
                .init(observesAppActivation: false, pollsFrontWindow: false),
                "Save my writing alone (screen memory \(screenMemory))"
            )
            assertEqual(
                WritingFrontWindowWatch.plan(running: false, autocompleteActive: true, screenMemoryEnabled: screenMemory),
                .init(observesAppActivation: false, pollsFrontWindow: false),
                "nothing while Writing is stopped (screen memory \(screenMemory))"
            )
        }
        assertEqual(
            WritingFrontWindowWatch.plan(running: true, autocompleteActive: true, screenMemoryEnabled: false),
            .init(observesAppActivation: true, pollsFrontWindow: false),
            "Autocomplete without Screen Memory keeps the prewarmer's app-switch observer, no poll"
        )
        assertEqual(
            WritingFrontWindowWatch.plan(running: true, autocompleteActive: true, screenMemoryEnabled: true),
            .init(observesAppActivation: true, pollsFrontWindow: true)
        )
    }

    runSuite("Paused Writing observes no app activations or windows and resumes its previous policy") {
        for screenMemory in [false, true] {
            assertEqual(
                WritingFrontWindowWatch.plan(running: true, autocompleteActive: true,
                                            screenMemoryEnabled: screenMemory, paused: true),
                .init(observesAppActivation: false, pollsFrontWindow: false)
            )
            assertEqual(
                WritingFrontWindowWatch.plan(running: true, autocompleteActive: true,
                                            screenMemoryEnabled: screenMemory, paused: false),
                .init(observesAppActivation: true, pollsFrontWindow: screenMemory)
            )
        }
    }

    runSuite("Writing setup completion is remembered in the given suite") {
        let suiteName = "WritingSetupStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        assertFalse(WritingSetupState.isCompleted(defaults: defaults), "a fresh install hasn't finished setup")
        WritingSetupState.markCompleted(defaults: defaults)
        assertTrue(WritingSetupState.isCompleted(defaults: defaults))
        assertEqual(WritingSetupState.completedKey, "WritingSetupCompleted")
    }

    runSuite("Writing storage meter splits model, saved writing and learning data") {
        let usage = WritingStorageUsage(savedWritingBytes: 250, learningBytes: 0, modelBytes: 750)
        assertEqual(usage.totalBytes, 1_000)
        assertEqual(usage.segments.map(\.label), ["Model", "Saved writing", "Learning data"])
        assertEqual(usage.segments.map(\.fraction), [0.75, 0.25, 0])
        assertFalse(usage.legend.contains("Learning data"), "empty parts stay out of the legend")
        assertTrue(usage.legend.hasPrefix("Model "))

        let empty = WritingStorageUsage(savedWritingBytes: 0, learningBytes: 0, modelBytes: 0)
        assertEqual(empty.summary, "Nothing stored yet")
        assertEqual(empty.segments.map(\.fraction), [0, 0, 0], "no division by zero")
        assertEqual(empty.legend, "")
    }

    runSuite("Writing storage counts only the day files and real files") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WritingSetupStateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writing = root.appendingPathComponent("writing", isDirectory: true)
        let models = root.appendingPathComponent("models/gemma", isDirectory: true)
        try? FileManager.default.createDirectory(at: writing, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try? Data(count: 10).write(to: writing.appendingPathComponent("Writing_2026-09-25.md"))
        try? Data(count: 20).write(to: writing.appendingPathComponent("Writing_2026-09-24.md"))
        try? Data(count: 400).write(to: writing.appendingPathComponent("notes.txt"))
        try? Data(count: 300).write(to: models.appendingPathComponent("model.gguf"))
        try? FileManager.default.createSymbolicLink(
            at: models.appendingPathComponent("link.gguf"),
            withDestinationURL: writing.appendingPathComponent("notes.txt")
        )

        assertEqual(WritingStorageUsage.dayFileBytes(in: writing), 30, "only Writing_*.md files count")
        assertEqual(WritingStorageUsage.fileBytes(under: models), 300, "symlinks aren't followed")
        assertEqual(
            WritingStorageUsage.dayFileBytes(in: root.appendingPathComponent("missing")),
            0,
            "a missing folder is empty"
        )
    }
}

import Foundation

// Behavioral coverage for when opt-in Writing capture runs
// (Sources/Writing/WritingSetupState.swift) and the saved-writing byte counter
// (Sources/Writing/WritingStorageUsage.swift).

func testWritingSetupState() {
    runSuite("Writing runs only while Save my writing is on (or dev debug override is set)") {
        assertFalse(
            WritingActivation.shouldRun(saveMyWriting: false, debugEnabled: false),
            "nothing runs when Save my writing is off"
        )
        assertTrue(
            WritingActivation.shouldRun(saveMyWriting: true, debugEnabled: false),
            "opting into Save my writing starts the capture listener"
        )
        assertTrue(
            WritingActivation.shouldRun(saveMyWriting: false, debugEnabled: true),
            "the development default still starts it"
        )
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

    runSuite("Writing storage summarizes saved day files") {
        let empty = WritingStorageUsage(savedWritingBytes: 0)
        assertEqual(empty.summary, "Nothing saved yet")

        let used = WritingStorageUsage(savedWritingBytes: 2_048)
        assertTrue(used.summary.hasSuffix("saved on this Mac"))
    }

    runSuite("Writing storage counts only real Writing_*.md day files") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WritingSetupStateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writing = root.appendingPathComponent("writing", isDirectory: true)
        try? FileManager.default.createDirectory(at: writing, withIntermediateDirectories: true)
        try? Data(count: 10).write(to: writing.appendingPathComponent("Writing_2026-09-25.md"))
        try? Data(count: 20).write(to: writing.appendingPathComponent("Writing_2026-09-24.md"))
        try? Data(count: 400).write(to: writing.appendingPathComponent("notes.txt"))
        try? FileManager.default.createSymbolicLink(
            at: writing.appendingPathComponent("Writing_2026-09-23.md"),
            withDestinationURL: writing.appendingPathComponent("notes.txt")
        )

        assertEqual(WritingStorageUsage.dayFileBytes(in: writing), 30, "only real Writing_*.md files count; symlinks and other files are skipped")
        assertEqual(
            WritingStorageUsage.dayFileBytes(in: root.appendingPathComponent("missing")),
            0,
            "a missing folder is empty"
        )
    }
}

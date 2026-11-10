import XCTest
@testable import transcripted_mcp

final class FileWatcherTests: XCTestCase {
    func testExistingFilesDoNotTriggerAnotherReconcileOnFirstScan() throws {
        let root = makeTempDir()
        defer { removeTempDir(root) }
        try writeFixture(makeFixtureJSON(), filename: "existing", to: root)
        var changes = 0
        var ticks = 0
        let watcher = FileWatcher(directory: root, onPeriodicTick: { ticks += 1 }) { changes += 1 }
        watcher.scanForChanges()
        watcher.periodicTick()
        XCTAssertEqual(changes, 0, "an unchanged startup snapshot is already covered by initial indexing")
        XCTAssertEqual(ticks, 1, "quiet ticks must still retry pending semantic work")
    }

    func testChangesBetweenSnapshotAndStartupAreNotLost() throws {
        let root = makeTempDir()
        defer { removeTempDir(root) }
        let file = root.appendingPathComponent("existing.md")
        try writeFixture(makeFixtureJSON(), filename: "existing", to: root)
        let initialDate = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        var changes = 0
        let watcher = FileWatcher(directory: root) { changes += 1 }

        // This can happen while the initial index pass is still running.
        try FileManager.default.setAttributes([.modificationDate: initialDate.addingTimeInterval(5)], ofItemAtPath: file.path)
        watcher.scanForChanges()
        XCTAssertEqual(changes, 1)
        watcher.scanForChanges()
        XCTAssertEqual(changes, 1, "unchanged scans must not repeat the catch-up reconcile")
        try FileManager.default.removeItem(at: file)
        watcher.scanForChanges()
        XCTAssertEqual(changes, 2, "deletions still reconcile")
        try writeFixture(makeFixtureJSON(), filename: "new", to: root)
        watcher.scanForChanges()
        XCTAssertEqual(changes, 3, "new files still reconcile")
    }
}

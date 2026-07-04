import Foundation

func testTimelineDatabase() {
    runSuite("Timeline storage paths create private app-owned screenshot folders") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineStoragePathsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 12)) ?? Date()
        let directory = root
            .appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
            .appendingPathComponent("2026-08-31", isDirectory: true)
        try? FileManager.default.createPrivateDirectory(at: directory)
        let fileURL = directory.appendingPathComponent("shot.jpg", isDirectory: false)
        try? Data("img".utf8).write(to: fileURL)
        FileManager.default.restrictFileToOwnerOnly(at: fileURL)

        let permissions = try? FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let filePermissions = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber

        assertEqual(permissions, NSNumber(value: 0o700), "timeline screenshot day folders should be owner-only")
        assertEqual(filePermissions, NSNumber(value: 0o600), "timeline screenshot files should be owner-only")
        assertEqual(
            FileManager.default.transcriptedTimelineScreenshotRelativePath(capturedAt: date, fileName: "shot.jpg"),
            "2026-08-31/shot.jpg",
            "timeline screenshot relative paths should be day-prefixed"
        )
        assertNil(
            FileManager.default.transcriptedTimelineScreenshotURL(relativePath: "../escape.jpg"),
            "timeline screenshot URL resolution should reject traversal"
        )
    }

    runSuite("TimelineDatabase migrations are idempotent and enable WAL") {
        let fixture = TimelineDatabaseFixture()
        defer { fixture.cleanup() }

        do {
            let db = try TimelineDatabase(databaseURL: fixture.databaseURL)
            assertEqual(try db.schemaVersion(), TimelineDatabase.currentSchemaVersion, "schema should migrate to current version")
            assertEqual(try db.journalMode().lowercased(), "wal", "timeline database should use WAL mode")

            let reopened = try TimelineDatabase(databaseURL: fixture.databaseURL)
            assertEqual(try reopened.schemaVersion(), TimelineDatabase.currentSchemaVersion, "reopening should not reapply migrations badly")
        } catch {
            assertTrue(false, "database migration should not throw: \(error)")
        }
    }

    runSuite("TimelineDatabase inserts and queries screenshot rows") {
        let fixture = TimelineDatabaseFixture()
        defer { fixture.cleanup() }

        do {
            let db = try TimelineDatabase(databaseURL: fixture.databaseURL)
            let id = try db.insertScreenshot(NewTimelineScreenshot(
                capturedAt: 100,
                filePath: "2026-07-03/shot.jpg",
                fileSize: 1234,
                idleSecondsAtCapture: 1.5,
                appBundleID: "com.apple.finder",
                appName: "Finder",
                windowTitle: "Desktop",
                displayID: 42
            ))
            let rows = try db.screenshots()
            assertEqual(rows.count, 1, "one screenshot should round-trip")
            assertEqual(rows.first?.id, id, "insert should return the row id")
            assertEqual(rows.first?.filePath, "2026-07-03/shot.jpg", "relative file path should round-trip")
            assertEqual(rows.first?.appName, "Finder", "app metadata should round-trip")
            assertEqual(rows.first?.displayID, 42, "display id should round-trip")
        } catch {
            assertTrue(false, "screenshot round-trip should not throw: \(error)")
        }
    }

    runSuite("TimelineRetentionManager purges oldest screenshots first over cap") {
        let fixture = TimelineDatabaseFixture()
        defer { fixture.cleanup() }

        do {
            let db = try TimelineDatabase(databaseURL: fixture.databaseURL)
            let first = try fixture.writeScreenshot(relativePath: "2026-07-03/001.jpg", bytes: 4)
            let second = try fixture.writeScreenshot(relativePath: "2026-07-03/002.jpg", bytes: 4)
            let third = try fixture.writeScreenshot(relativePath: "2026-07-03/003.jpg", bytes: 4)
            _ = first
            _ = second
            _ = third
            _ = try db.insertScreenshot(NewTimelineScreenshot(capturedAt: 10, filePath: "2026-07-03/001.jpg", fileSize: 4, idleSecondsAtCapture: 0))
            _ = try db.insertScreenshot(NewTimelineScreenshot(capturedAt: 20, filePath: "2026-07-03/002.jpg", fileSize: 4, idleSecondsAtCapture: 0))
            _ = try db.insertScreenshot(NewTimelineScreenshot(capturedAt: 30, filePath: "2026-07-03/003.jpg", fileSize: 4, idleSecondsAtCapture: 0))

            let manager = TimelineRetentionManager(database: db, screenshotsRoot: fixture.screenshotsRoot)
            let summary = try manager.runRetentionPass(storageCapBytes: 8)
            let rows = try db.screenshots()

            assertEqual(summary.deletedFiles, 1, "retention should delete one oldest file to reach the cap")
            assertFalse(FileManager.default.fileExists(atPath: fixture.url("2026-07-03/001.jpg").path), "oldest file should be removed first")
            assertTrue(FileManager.default.fileExists(atPath: fixture.url("2026-07-03/002.jpg").path), "newer file should remain")
            assertEqual(rows.map(\.filePath), ["2026-07-03/002.jpg", "2026-07-03/003.jpg"], "oldest row should be hard-deleted after file removal")
        } catch {
            assertTrue(false, "retention purge should not throw: \(error)")
        }
    }

    runSuite("TimelineRetentionManager respects processing batch guard") {
        let fixture = TimelineDatabaseFixture()
        defer { fixture.cleanup() }

        do {
            let db = try TimelineDatabase(databaseURL: fixture.databaseURL)
            try fixture.writeScreenshot(relativePath: "2026-07-03/001.jpg", bytes: 4)
            try fixture.writeScreenshot(relativePath: "2026-07-03/002.jpg", bytes: 4)
            let protectedID = try db.insertScreenshot(NewTimelineScreenshot(capturedAt: 10, filePath: "2026-07-03/001.jpg", fileSize: 4, idleSecondsAtCapture: 0))
            _ = try db.insertScreenshot(NewTimelineScreenshot(capturedAt: 20, filePath: "2026-07-03/002.jpg", fileSize: 4, idleSecondsAtCapture: 0))
            _ = try db.insertAnalysisBatch(start: 0, end: 30, status: "processing", screenshotIDs: [protectedID])

            let manager = TimelineRetentionManager(database: db, screenshotsRoot: fixture.screenshotsRoot)
            _ = try manager.runRetentionPass(storageCapBytes: 4)
            let rows = try db.screenshots()

            assertTrue(FileManager.default.fileExists(atPath: fixture.url("2026-07-03/001.jpg").path), "processing screenshot file should stay on disk")
            assertFalse(FileManager.default.fileExists(atPath: fixture.url("2026-07-03/002.jpg").path), "unprotected screenshot should be purged")
            assertEqual(rows.map(\.filePath), ["2026-07-03/001.jpg"], "processing screenshot row should remain")
        } catch {
            assertTrue(false, "processing guard purge should not throw: \(error)")
        }
    }

    runSuite("TimelineRetentionManager removes orphan files") {
        let fixture = TimelineDatabaseFixture()
        defer { fixture.cleanup() }

        do {
            let db = try TimelineDatabase(databaseURL: fixture.databaseURL)
            try fixture.writeScreenshot(relativePath: "2026-07-03/known.jpg", bytes: 4)
            try fixture.writeScreenshot(relativePath: "2026-07-03/orphan.jpg", bytes: 4)
            _ = try db.insertScreenshot(NewTimelineScreenshot(capturedAt: 10, filePath: "2026-07-03/known.jpg", fileSize: 4, idleSecondsAtCapture: 0))

            let manager = TimelineRetentionManager(database: db, screenshotsRoot: fixture.screenshotsRoot)
            let summary = try manager.runRetentionPass(storageCapBytes: 100)

            assertEqual(summary.deletedOrphanFiles, 1, "orphan cleanup should remove files with no database row")
            assertTrue(FileManager.default.fileExists(atPath: fixture.url("2026-07-03/known.jpg").path), "known screenshot should stay")
            assertFalse(FileManager.default.fileExists(atPath: fixture.url("2026-07-03/orphan.jpg").path), "orphan screenshot should be removed")
        } catch {
            assertTrue(false, "orphan cleanup should not throw: \(error)")
        }
    }
}

private final class TimelineDatabaseFixture {
    let root: URL
    let databaseURL: URL
    let screenshotsRoot: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = root
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("timeline.sqlite", isDirectory: false)
        screenshotsRoot = root
            .appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
        try? FileManager.default.createPrivateDirectory(at: screenshotsRoot)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func writeScreenshot(relativePath: String, bytes: Int) throws -> URL {
        let url = self.url(relativePath)
        try FileManager.default.createPrivateDirectory(at: url.deletingLastPathComponent())
        try Data(repeating: 1, count: bytes).write(to: url)
        FileManager.default.restrictFileToOwnerOnly(at: url)
        return url
    }

    func url(_ relativePath: String) -> URL {
        screenshotsRoot.appendingPathComponent(relativePath, isDirectory: false)
    }
}

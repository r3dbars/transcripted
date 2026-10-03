import Foundation

// Promise: queued heartbeat writes leave the caller right away, land in order
// with the newest snapshot winning, and a synchronous write (launch, session
// stage, clean shutdown) is on disk when it returns and is never overwritten
// by an older queued heartbeat.
func testRuntimeDiagnosticsMarkerWriter() {
    runSuite("clean-shutdown marker is never overwritten by an earlier queued write") {
        let firstSaveStarted = DispatchSemaphore(value: 0)
        let releaseFirstSave = DispatchSemaphore(value: 0)
        let log = MarkerSaveLog()
        let writer = RuntimeDiagnosticsMarkerWriter(url: markerTestURL()) { marker, _ in
            if marker.lastEvent == "heartbeat" {
                firstSaveStarted.signal()
                // Failure watchdog only; no assertion on scheduling speed.
                _ = releaseFirstSave.wait(timeout: .now() + 30)
            }
            log.append(marker, isMainThread: Thread.isMainThread)
        }

        writer.submit(markerFixture(lastEvent: "heartbeat"))
        guard firstSaveStarted.wait(timeout: .now() + 30) == .success else {
            releaseFirstSave.signal()
            assertTrue(false, "the marker worker did not start")
            return
        }
        // The first save is stalled; submit must still return.
        writer.submit(markerFixture(lastEvent: "heartbeat_later"))

        let cleanWritten = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            writer.writeNow(markerFixture(lastEvent: "clean_shutdown", cleanShutdown: true))
            cleanWritten.signal()
        }
        releaseFirstSave.signal()
        guard cleanWritten.wait(timeout: .now() + 30) == .success else {
            assertTrue(false, "writeNow did not return")
            return
        }

        let saved = log.events
        assertEqual(saved.last, "clean_shutdown", "the clean marker is the last write")
        assertEqual(saved.filter { $0 == "clean_shutdown" }.count, 1, "the clean marker is written once")
        assertEqual(saved.first, "heartbeat", "the queued heartbeats ran first, in order")
        assertFalse(log.usedMainThread, "marker saves never run on the main thread")
    }

    runSuite("latest runtime marker wins after a stalled save") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeDiagnosticsMarkerWriterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime-diagnostics.json", isDirectory: false)

        let firstSaveStarted = DispatchSemaphore(value: 0)
        let releaseFirstSave = DispatchSemaphore(value: 0)
        let writer = RuntimeDiagnosticsMarkerWriter(url: url) { marker, destination in
            if marker.lastEvent == "a" {
                firstSaveStarted.signal()
                _ = releaseFirstSave.wait(timeout: .now() + 30)
            }
            RuntimeDiagnosticsStore.save(marker, to: destination)
        }

        writer.submit(markerFixture(lastEvent: "a"))
        guard firstSaveStarted.wait(timeout: .now() + 30) == .success else {
            releaseFirstSave.signal()
            assertTrue(false, "the marker worker did not start")
            return
        }
        writer.submit(markerFixture(lastEvent: "b"))
        writer.submit(markerFixture(lastEvent: "c"))
        releaseFirstSave.signal()
        writer.writeNow(markerFixture(lastEvent: "d"))

        assertEqual(RuntimeDiagnosticsStore.load(from: url), markerFixture(lastEvent: "d"), "the synchronous write is what's on disk")
    }

    runSuite("runtime marker lands owner-only even when its folder was deleted") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeDiagnosticsMarkerWriterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("missing", isDirectory: true)
        let url = folder.appendingPathComponent("runtime-diagnostics.json", isDirectory: false)
        let marker = markerFixture(lastEvent: "dictation_recording")

        RuntimeDiagnosticsStore.save(marker, to: url)

        assertEqual(RuntimeDiagnosticsStore.load(from: url), marker, "the marker round-trips")
        let fileMode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        let folderMode = (try? FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue
        assertEqual(fileMode, 0o600, "the marker file is owner-only")
        assertEqual(folderMode, 0o700, "the marker folder is owner-only")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".tmp") }
        assertEqual(leftovers, [], "no temp files are left behind")

        // A second save replaces the file in place and stays owner-only.
        let updated = markerFixture(lastEvent: "dictation_completed")
        RuntimeDiagnosticsStore.save(updated, to: url)
        assertEqual(RuntimeDiagnosticsStore.load(from: url), updated, "a later save replaces the marker")
        let updatedMode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        assertEqual(updatedMode, 0o600, "the replaced marker is still owner-only")
    }
}

private func markerTestURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("RuntimeDiagnosticsMarkerWriterTests-unused-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("runtime-diagnostics.json", isDirectory: false)
}

private func markerFixture(lastEvent: String, cleanShutdown: Bool = false) -> RuntimeDiagnosticsMarker {
    RuntimeDiagnosticsMarker(
        launchID: "launch-1",
        appVersion: "1.2.3",
        buildVersion: "456",
        buildChannel: "local",
        buildRevision: "abc123",
        osMajor: 26,
        cleanShutdown: cleanShutdown,
        startedAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 1_100),
        lastEvent: lastEvent,
        sessionKind: "dictation",
        sessionStage: "recording",
        sessionActive: true
    )
}

private final class MarkerSaveLog: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [String] = []
    private var onMain = false

    func append(_ marker: RuntimeDiagnosticsMarker, isMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        saved.append(marker.lastEvent)
        onMain = onMain || isMainThread
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return saved
    }

    var usedMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onMain
    }
}

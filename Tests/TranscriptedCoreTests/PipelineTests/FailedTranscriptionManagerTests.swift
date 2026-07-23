import AVFoundation
import Combine
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class FailedTranscriptionManagerTests: XCTestCase {
    private var testRoot: URL!

    override func setUpWithError() throws {
        let homeRoot = FileManager.default.homeDirectoryForCurrentUser
        testRoot = homeRoot
            .appendingPathComponent("Library/Application Support/TranscriptedTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
        testRoot = nil
    }

    func testInitRejectsOutOfHomeAudioPathsAndRewritesQueue() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let safeMicURL = paths.audioCaptures.appendingPathComponent("safe-mic.wav")
        let safeSystemURL = paths.audioCaptures.appendingPathComponent("safe-system.wav")
        FileManager.default.createFile(atPath: safeMicURL.path, contents: Data("mic".utf8))
        FileManager.default.createFile(atPath: safeSystemURL.path, contents: Data("system".utf8))
        let traversalTargetURL = testRoot.appendingPathComponent("outside.wav")
        FileManager.default.createFile(atPath: traversalTargetURL.path, contents: Data("outside".utf8))
        let traversalMicURL = URL(fileURLWithPath: paths.audioCaptures.path + "/../../outside.wav")
        let documentsURL = testRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        let homeFileURL = documentsURL.appendingPathComponent("foo.wav")
        FileManager.default.createFile(atPath: homeFileURL.path, contents: Data("home".utf8))

        let safeEntry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            micAudioURL: safeMicURL,
            systemAudioURL: safeSystemURL,
            errorMessage: "Temporary transcription failure"
        )
        let unsafeMicEntry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 2_000),
            micAudioURL: URL(fileURLWithPath: "/tmp/transcripted-unsafe-mic.wav"),
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )
        let unsafeSystemEntry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 3_000),
            micAudioURL: safeMicURL,
            systemAudioURL: URL(fileURLWithPath: "/tmp/transcripted-unsafe-system.wav"),
            errorMessage: "Temporary transcription failure"
        )
        let traversalEntry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 4_000),
            micAudioURL: traversalMicURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )
        let arbitraryHomeEntry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 5_000),
            micAudioURL: homeFileURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )

        let encoded = try JSONEncoder.iso8601.encode([
            safeEntry,
            unsafeMicEntry,
            unsafeSystemEntry,
            traversalEntry,
            arbitraryHomeEntry,
        ])
        try FileManager.default.createDirectory(
            at: paths.failedQueue.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoded.write(to: paths.failedQueue, options: .atomic)

        let manager = FailedTranscriptionManager(paths: paths)

        XCTAssertEqual(manager.failedTranscriptions, [safeEntry])

        let persisted = try JSONDecoder.iso8601.decode(
            [FailedTranscription].self,
            from: Data(contentsOf: paths.failedQueue)
        )
        XCTAssertEqual(persisted, [safeEntry])
    }

    func testAddFailedTranscriptionRejectsOutOfSandboxAudioPaths() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let safeMicURL = paths.audioCaptures.appendingPathComponent("safe-mic.wav")
        FileManager.default.createFile(atPath: safeMicURL.path, contents: Data("mic".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        manager.addFailedTranscription(
            micAudioURL: URL(fileURLWithPath: "/tmp/transcripted-unsafe-mic.wav"),
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )
        manager.addFailedTranscription(
            micAudioURL: safeMicURL,
            systemAudioURL: URL(fileURLWithPath: "/tmp/transcripted-unsafe-system.wav"),
            errorMessage: "Temporary transcription failure"
        )

        XCTAssertTrue(manager.failedTranscriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.failedQueue.path))
    }

    func testAddFailedTranscriptionAcceptsRetainedMeetingAudioArchivePaths() throws {
        let paths = makePaths(root: testRoot)
        let archiveRoot = paths.transcripts.appendingPathComponent("audio", isDirectory: true)
        let archivedDirectory = archiveRoot.appendingPathComponent("Failed_Call_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: archivedDirectory, withIntermediateDirectories: true)

        let archivedMicURL = archivedDirectory.appendingPathComponent("microphone.wav")
        let archivedSystemURL = archivedDirectory.appendingPathComponent("system_audio.wav")
        FileManager.default.createFile(atPath: archivedMicURL.path, contents: Data("mic".utf8))
        FileManager.default.createFile(atPath: archivedSystemURL.path, contents: Data("system".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        manager.addFailedTranscription(
            micAudioURL: archivedMicURL,
            systemAudioURL: archivedSystemURL,
            errorMessage: "Temporary transcription failure"
        )

        XCTAssertEqual(manager.failedTranscriptions.count, 1)
        XCTAssertEqual(manager.failedTranscriptions.first?.micAudioURL, archivedMicURL)
        XCTAssertEqual(manager.failedTranscriptions.first?.systemAudioURL, archivedSystemURL)

        let siblingArchiveURL = paths.transcripts
            .deletingLastPathComponent()
            .appendingPathComponent("audio/sibling.wav")
        try FileManager.default.createDirectory(
            at: siblingArchiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: siblingArchiveURL.path, contents: Data("sibling".utf8))

        manager.addFailedTranscription(
            micAudioURL: siblingArchiveURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )

        XCTAssertEqual(manager.failedTranscriptions.count, 1)
    }

    func testDeleteFailedTranscriptionRemovesTinyRetainedAudioAndQueueEntry() throws {
        let paths = makePaths(root: testRoot)
        let archiveRoot = paths.transcripts.appendingPathComponent("audio", isDirectory: true)
        let archivedDirectory = archiveRoot.appendingPathComponent("Tiny_Recoverable_Call_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: archivedDirectory, withIntermediateDirectories: true)

        let archivedMicURL = archivedDirectory.appendingPathComponent("microphone.wav")
        let archivedSystemURL = archivedDirectory.appendingPathComponent("system_audio.wav")
        FileManager.default.createFile(atPath: archivedMicURL.path, contents: Data([0x01]))
        FileManager.default.createFile(atPath: archivedSystemURL.path, contents: Data([0x02]))

        let manager = FailedTranscriptionManager(paths: paths)
        let failedId = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedId,
            micAudioURL: archivedMicURL,
            systemAudioURL: archivedSystemURL,
            errorMessage: "Meeting saved before quit. Audio is safe; finish the transcript from Home after reopening."
        ))

        XCTAssertTrue(manager.deleteFailedTranscription(id: failedId))
        XCTAssertTrue(manager.failedTranscriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archivedMicURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archivedSystemURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archivedDirectory.path))

        let persisted = try JSONDecoder.iso8601.decode(
            [FailedTranscription].self,
            from: Data(contentsOf: paths.failedQueue)
        )
        XCTAssertTrue(persisted.isEmpty)
    }

    func testDeleteFailedTranscriptionRemovesEveryJournalOwnedScratchSegment() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        let primaryURL = paths.audioCaptures.appendingPathComponent("timeout-mic.wav")
        let recoveryURL = paths.audioCaptures.appendingPathComponent("timeout-recovery.wav")
        let systemURL = paths.audioCaptures.appendingPathComponent("timeout-system.wav")
        let journalURL = paths.audioCaptures.appendingPathComponent("timeout-mic.recording.json")
        for url in [primaryURL, recoveryURL, systemURL] {
            FileManager.default.createFile(atPath: url.path, contents: Data("owned".utf8))
        }
        let journal = MeetingRecordingJournalStore(directory: paths.audioCaptures)
        let session = journal.begin(primaryMicURL: primaryURL)
        journal.recordSegments([
            MicRecordingSegment(url: primaryURL),
            MicRecordingSegment(url: recoveryURL, gapBeforeDuration: 0.1),
        ], session: session)
        journal.recordSystemAudio(systemURL, session: session)
        journal.markStopping(session: session)
        journal.flush()

        let manager = FailedTranscriptionManager(paths: paths)
        let failedID = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedID,
            micAudioURL: primaryURL,
            systemAudioURL: systemURL,
            errorMessage: "Recording stop timed out before audio files were finalized."
        ))

        XCTAssertTrue(manager.deleteFailedTranscription(id: failedID))

        for url in [primaryURL, recoveryURL, systemURL, journalURL] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testOldFailureCleanupConsumesRetainedJournalInventory() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        let primaryURL = paths.audioCaptures.appendingPathComponent("old-timeout-mic.wav")
        let recoveryURL = paths.audioCaptures.appendingPathComponent("old-timeout-recovery.wav")
        let journalURL = paths.audioCaptures.appendingPathComponent("old-timeout-mic.recording.json")
        for url in [primaryURL, recoveryURL] {
            FileManager.default.createFile(atPath: url.path, contents: Data("owned".utf8))
        }
        let journal = MeetingRecordingJournalStore(directory: paths.audioCaptures)
        let session = journal.begin(primaryMicURL: primaryURL)
        journal.recordSegments([
            MicRecordingSegment(url: primaryURL),
            MicRecordingSegment(url: recoveryURL, gapBeforeDuration: 0.1),
        ], session: session)
        journal.markStopping(session: session)
        journal.flush()

        let manager = FailedTranscriptionManager(paths: paths)
        let failedID = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedID,
            micAudioURL: primaryURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized."
        ))
        manager.failedTranscriptions[0] = FailedTranscription(
            id: failedID,
            timestamp: Date(timeIntervalSinceNow: -10 * 24 * 60 * 60),
            micAudioURL: primaryURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized."
        )

        manager.cleanupOldFailedTranscriptions(olderThanDays: 7)

        XCTAssertTrue(manager.failedTranscriptions.isEmpty)
        for url in [primaryURL, recoveryURL, journalURL] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testDeleteRechecksJournalContainmentForMutatedInMemoryEntry() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        let safeMicURL = paths.audioCaptures.appendingPathComponent("safe-mic.wav")
        FileManager.default.createFile(atPath: safeMicURL.path, contents: Data("safe".utf8))
        let outsideDirectory = testRoot.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideMicURL = outsideDirectory.appendingPathComponent("private-mic.wav")
        let outsideJournalURL = outsideDirectory.appendingPathComponent("private-mic.recording.json")
        FileManager.default.createFile(atPath: outsideMicURL.path, contents: Data("private".utf8))
        FileManager.default.createFile(atPath: outsideJournalURL.path, contents: Data("private".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        let failedID = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedID,
            micAudioURL: safeMicURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        ))
        manager.failedTranscriptions[0] = FailedTranscription(
            id: failedID,
            micAudioURL: outsideMicURL,
            systemAudioURL: nil,
            errorMessage: "Tampered in-memory path"
        )

        XCTAssertTrue(manager.deleteFailedTranscription(id: failedID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideMicURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideJournalURL.path))
    }

    func testDeleteFailedTranscriptionFinishesFromPendingMarkerWhenQueuePersistenceFails() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let micURL = paths.audioCaptures.appendingPathComponent("safe-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        let failedId = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedId,
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        ))
        let failure = try XCTUnwrap(manager.failedTranscriptions.first)
        var publishedQueues: [[FailedTranscription]] = []
        let subscription = manager.$failedTranscriptions
            .dropFirst()
            .sink { publishedQueues.append($0) }
        defer { subscription.cancel() }

        try FileManager.default.removeItem(at: paths.failedQueue)
        try FileManager.default.createDirectory(at: paths.failedQueue, withIntermediateDirectories: true)

        XCTAssertTrue(manager.deleteFailedTranscription(id: failedId))
        XCTAssertTrue(manager.failedTranscriptions.isEmpty)
        XCTAssertEqual(publishedQueues.count, 1)
        XCTAssertTrue(publishedQueues[0].isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        let pendingDeletionURL = paths.failedQueue.deletingLastPathComponent()
            .appendingPathComponent(FailedTranscriptionManager.pendingDeletionFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDeletionURL.path))

        // Simulate the unavailable queue becoming writable before relaunch.
        try FileManager.default.removeItem(at: paths.failedQueue)
        try JSONEncoder.iso8601.encode([failure]).write(to: paths.failedQueue, options: .atomic)
        let relaunched = FailedTranscriptionManager(paths: paths)
        XCTAssertTrue(relaunched.failedTranscriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDeletionURL.path))
    }

    func testDeleteFailedTranscriptionKeepsRowWhenArtifactCleanupIsDenied() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        let micURL = paths.audioCaptures.appendingPathComponent("permission-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        let journal = MeetingRecordingJournalStore(directory: paths.audioCaptures)
        let session = journal.begin(primaryMicURL: micURL)
        journal.markStopping(session: session)
        journal.flush()
        let journalURL = paths.audioCaptures.appendingPathComponent(
            "permission-mic" + MeetingRecordingJournalStore.filenameSuffix
        )

        let manager = FailedTranscriptionManager(paths: paths)
        let failedID = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedID,
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized."
        ))
        let originalQueue = manager.failedTranscriptions
        var publishedQueues: [[FailedTranscription]] = []
        let subscription = manager.$failedTranscriptions
            .dropFirst()
            .sink { publishedQueues.append($0) }
        defer {
            subscription.cancel()
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: paths.audioCaptures.path
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: paths.audioCaptures.path
        )

        XCTAssertFalse(manager.deleteFailedTranscription(id: failedID))
        XCTAssertEqual(manager.failedTranscriptions, originalQueue)
        XCTAssertTrue(publishedQueues.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        let pendingDeletionURL = paths.failedQueue.deletingLastPathComponent()
            .appendingPathComponent(FailedTranscriptionManager.pendingDeletionFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDeletionURL.path))
        XCTAssertFalse(
            manager.removeFailedTranscription(id: failedID),
            "an alternate completion cannot bypass durable artifact cleanup"
        )
        XCTAssertThrowsError(try manager.healMissingAudioReferencesForRetry(id: failedID)) { error in
            guard case FailedTranscriptionManager.AudioReferenceHealingError.deletionPending = error else {
                return XCTFail("expected deletionPending, got \(type(of: error))")
            }
        }
        XCTAssertEqual(manager.failedTranscriptions, originalQueue)

        let persisted = try JSONDecoder.iso8601.decode(
            [FailedTranscription].self,
            from: Data(contentsOf: paths.failedQueue)
        )
        XCTAssertEqual(persisted.map(\.id), originalQueue.map(\.id))
        XCTAssertEqual(persisted.map(\.micAudioURL), originalQueue.map(\.micAudioURL))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: paths.audioCaptures.path
        )
        let relaunched = FailedTranscriptionManager(paths: paths)
        XCTAssertTrue(relaunched.failedTranscriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDeletionURL.path))
    }

    func testPendingDeletionRejectsLateAudioRepointAndJournalDeletesFinalizedInventory() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        let micURL = paths.audioCaptures.appendingPathComponent("pending-mic.wav")
        let mergedURL = paths.audioCaptures.appendingPathComponent("pending-mic_merged.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        let journal = MeetingRecordingJournalStore(directory: paths.audioCaptures)
        let session = journal.begin(primaryMicURL: micURL)
        journal.markStopping(session: session)
        journal.flush()

        let manager = FailedTranscriptionManager(paths: paths)
        let failedID = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedID,
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized."
        ))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: paths.audioCaptures.path
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: paths.audioCaptures.path
        )
        XCTAssertFalse(manager.deleteFailedTranscription(id: failedID))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: paths.audioCaptures.path
        )
        FileManager.default.createFile(atPath: mergedURL.path, contents: Data("merged".utf8))
        journal.markFinalized(finalMicURL: mergedURL, session: session)
        journal.flush()

        XCTAssertFalse(manager.updateFailedTranscriptionAudio(
            id: failedID,
            micAudioURL: mergedURL,
            systemAudioURL: nil
        ))
        XCTAssertEqual(manager.failedTranscriptions.first?.micAudioURL, micURL)

        let relaunched = FailedTranscriptionManager(paths: paths)
        XCTAssertTrue(relaunched.failedTranscriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mergedURL.path))
        XCTAssertFalse(MeetingRecordingJournalStore.hasJournal(forMicAudioURL: micURL))
    }

    func testPendingDeletionWaitsForUnavailableAudioRoot() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        let micURL = paths.audioCaptures.appendingPathComponent("offline-mic.wav")
        let micData = Data("mic".utf8)
        FileManager.default.createFile(atPath: micURL.path, contents: micData)

        let manager = FailedTranscriptionManager(paths: paths)
        let failedID = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedID,
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: paths.audioCaptures.path
        )
        XCTAssertFalse(manager.deleteFailedTranscription(id: failedID))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: paths.audioCaptures.path
        )
        try FileManager.default.removeItem(at: paths.audioCaptures)

        let pendingDeletionURL = paths.failedQueue.deletingLastPathComponent()
            .appendingPathComponent(FailedTranscriptionManager.pendingDeletionFilename)
        let offlineRelaunch = FailedTranscriptionManager(paths: paths)
        XCTAssertEqual(offlineRelaunch.failedTranscriptions.map(\.id), [failedID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDeletionURL.path))

        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: micURL.path, contents: micData)
        let availableRelaunch = FailedTranscriptionManager(paths: paths)
        XCTAssertTrue(availableRelaunch.failedTranscriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDeletionURL.path))
    }

    func testPendingDeletionIgnoresInjectedAudioPaths() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        let rowMicURL = paths.audioCaptures.appendingPathComponent("row-mic.wav")
        let unrelatedURL = paths.audioCaptures.appendingPathComponent("unrelated-private.wav")
        FileManager.default.createFile(atPath: rowMicURL.path, contents: Data("row".utf8))
        FileManager.default.createFile(atPath: unrelatedURL.path, contents: Data("unrelated".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        let failedID = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedID,
            micAudioURL: rowMicURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        ))
        let pendingDeletionURL = paths.failedQueue.deletingLastPathComponent()
            .appendingPathComponent(FailedTranscriptionManager.pendingDeletionFilename)
        let injectedMarker = try JSONSerialization.data(withJSONObject: [[
            "id": failedID.uuidString,
            "micAudioURL": unrelatedURL.absoluteString,
        ]])
        try injectedMarker.write(to: pendingDeletionURL, options: .atomic)

        let relaunched = FailedTranscriptionManager(paths: paths)
        XCTAssertTrue(relaunched.failedTranscriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rowMicURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDeletionURL.path))
    }

    func testCorruptPendingDeletionMarkerFailsClosed() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        let micURL = paths.audioCaptures.appendingPathComponent("kept-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        let failedID = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedID,
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        ))
        let pendingDeletionURL = paths.failedQueue.deletingLastPathComponent()
            .appendingPathComponent(FailedTranscriptionManager.pendingDeletionFilename)
        let corruptData = Data("not-json".utf8)
        try corruptData.write(to: pendingDeletionURL, options: .atomic)

        let relaunched = FailedTranscriptionManager(paths: paths)
        XCTAssertEqual(relaunched.failedTranscriptions.map(\.id), [failedID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertEqual(try Data(contentsOf: pendingDeletionURL), corruptData)
    }

    func testPendingDeletionSurvivesCorruptQueueUntilCanonicalRowReturns() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: paths.failedQueue.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let micURL = paths.audioCaptures.appendingPathComponent("corrupt-queue-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        let journal = MeetingRecordingJournalStore(directory: paths.audioCaptures)
        let session = journal.begin(primaryMicURL: micURL)
        journal.markStopping(session: session)
        journal.flush()
        let failed = FailedTranscription(
            id: UUID(),
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )
        let pendingDeletionURL = paths.failedQueue.deletingLastPathComponent()
            .appendingPathComponent(FailedTranscriptionManager.pendingDeletionFilename)
        let marker = try JSONSerialization.data(withJSONObject: [["id": failed.id.uuidString]])
        try marker.write(to: pendingDeletionURL, options: .atomic)
        try Data("not-a-queue".utf8).write(to: paths.failedQueue, options: .atomic)

        let corruptRelaunch = FailedTranscriptionManager(paths: paths)
        XCTAssertTrue(corruptRelaunch.failedTranscriptions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDeletionURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(MeetingRecordingJournalStore.hasJournal(forMicAudioURL: micURL))

        try JSONEncoder.iso8601.encode([failed]).write(to: paths.failedQueue, options: .atomic)
        let recoveredRelaunch = FailedTranscriptionManager(paths: paths)
        XCTAssertTrue(recoveredRelaunch.failedTranscriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDeletionURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(MeetingRecordingJournalStore.hasJournal(forMicAudioURL: micURL))
    }

    func testPendingDeletionSurvivesMissingQueueUntilCanonicalRowReturns() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: paths.failedQueue.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let micURL = paths.audioCaptures.appendingPathComponent("missing-queue-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        let failed = FailedTranscription(
            id: UUID(),
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )
        let pendingDeletionURL = paths.failedQueue.deletingLastPathComponent()
            .appendingPathComponent(FailedTranscriptionManager.pendingDeletionFilename)
        let marker = try JSONSerialization.data(withJSONObject: [["id": failed.id.uuidString]])
        try marker.write(to: pendingDeletionURL, options: .atomic)

        let missingRelaunch = FailedTranscriptionManager(paths: paths)
        XCTAssertTrue(missingRelaunch.failedTranscriptions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDeletionURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))

        try JSONEncoder.iso8601.encode([failed]).write(to: paths.failedQueue, options: .atomic)
        let recoveredRelaunch = FailedTranscriptionManager(paths: paths)
        XCTAssertTrue(recoveredRelaunch.failedTranscriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDeletionURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
    }

    func testPendingDeletionSidecarRemovalNeverRecursesIntoDirectory() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        let micURL = paths.audioCaptures.appendingPathComponent("sidecar-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        let manager = FailedTranscriptionManager(paths: paths)
        let failedID = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedID,
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        ))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: paths.audioCaptures.path
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: paths.audioCaptures.path
        )
        XCTAssertFalse(manager.deleteFailedTranscription(id: failedID))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: paths.audioCaptures.path
        )

        let pendingDeletionURL = paths.failedQueue.deletingLastPathComponent()
            .appendingPathComponent(FailedTranscriptionManager.pendingDeletionFilename)
        try FileManager.default.removeItem(at: pendingDeletionURL)
        try FileManager.default.createDirectory(at: pendingDeletionURL, withIntermediateDirectories: true)
        let sentinelURL = pendingDeletionURL.appendingPathComponent("keep.txt")
        FileManager.default.createFile(atPath: sentinelURL.path, contents: Data("keep".utf8))

        XCTAssertTrue(manager.deleteFailedTranscription(id: failedID))
        XCTAssertTrue(manager.failedTranscriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
    }

    func testAddFailedTranscriptionPersistsMeetingTitle() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let micURL = paths.audioCaptures.appendingPathComponent("safe-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        manager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure",
            meetingTitle: "Meeting with Linus"
        )

        XCTAssertEqual(manager.failedTranscriptions.first?.meetingTitle, "Meeting with Linus")

        let persisted = try JSONDecoder.iso8601.decode(
            [FailedTranscription].self,
            from: Data(contentsOf: paths.failedQueue)
        )
        XCTAssertEqual(persisted.first?.meetingTitle, "Meeting with Linus")
    }

    func testUpdateFailedTranscriptionErrorPreservesMeetingTitle() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let micURL = paths.audioCaptures.appendingPathComponent("safe-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        manager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure",
            meetingTitle: "Design review"
        )
        let failed = try XCTUnwrap(manager.failedTranscriptions.first)

        XCTAssertTrue(manager.updateFailedTranscriptionError(
            id: failed.id,
            errorMessage: "Speaker names could not be saved."
        ))

        XCTAssertEqual(manager.failedTranscriptions.first?.meetingTitle, "Design review")

        let persisted = try JSONDecoder.iso8601.decode(
            [FailedTranscription].self,
            from: Data(contentsOf: paths.failedQueue)
        )
        XCTAssertEqual(persisted.first?.meetingTitle, "Design review")
    }

    func testUpdateFailedTranscriptionErrorRollsBackMemoryWhenPersistenceFails() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let micURL = paths.audioCaptures.appendingPathComponent("safe-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        let failedId = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedId,
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure",
            meetingTitle: "Queue retry"
        ))
        let original = try XCTUnwrap(manager.failedTranscriptions.first)

        try FileManager.default.removeItem(at: paths.failedQueue)
        try FileManager.default.createDirectory(at: paths.failedQueue, withIntermediateDirectories: true)

        XCTAssertFalse(manager.updateFailedTranscriptionError(
            id: failedId,
            errorMessage: "Retry failed: model not ready"
        ))
        XCTAssertEqual(
            manager.failedTranscriptions.first,
            original,
            "the visible failed queue should not drift from durable storage when retry-state persistence fails"
        )
    }

    func testUpdateFailedTranscriptionAudioPreservesRetryMetadata() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let firstMicURL = paths.audioCaptures.appendingPathComponent("timeout-segment.wav")
        let finalMicURL = paths.audioCaptures.appendingPathComponent("timeout-merged.wav")
        let systemURL = paths.audioCaptures.appendingPathComponent("timeout-system.wav")
        FileManager.default.createFile(atPath: firstMicURL.path, contents: Data("mic".utf8))
        FileManager.default.createFile(atPath: finalMicURL.path, contents: Data("merged".utf8))
        FileManager.default.createFile(atPath: systemURL.path, contents: Data("system".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        let failedId = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedId,
            micAudioURL: firstMicURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            meetingTitle: "Design review"
        ))
        manager.incrementRetryCount(id: failedId)

        XCTAssertTrue(manager.updateFailedTranscriptionAudio(
            id: failedId,
            micAudioURL: finalMicURL,
            systemAudioURL: systemURL
        ))

        let failed = try XCTUnwrap(manager.failedTranscriptions.first)
        XCTAssertEqual(failed.id, failedId)
        XCTAssertEqual(failed.micAudioURL, finalMicURL)
        XCTAssertEqual(failed.systemAudioURL, systemURL)
        XCTAssertEqual(failed.errorMessage, "Recording stop timed out before audio files were finalized.")
        XCTAssertEqual(failed.meetingTitle, "Design review")
        XCTAssertEqual(failed.retryCount, 1)
        XCTAssertNotNil(failed.lastRetryDate)

        let persisted = try JSONDecoder.iso8601.decode(
            [FailedTranscription].self,
            from: Data(contentsOf: paths.failedQueue)
        )
        XCTAssertEqual(persisted.first?.micAudioURL, finalMicURL)
        XCTAssertEqual(persisted.first?.systemAudioURL, systemURL)
    }

    func testUpdateFailedTranscriptionAudioRollsBackMemoryWhenPersistenceFails() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let firstMicURL = paths.audioCaptures.appendingPathComponent("timeout-segment.wav")
        let finalMicURL = paths.audioCaptures.appendingPathComponent("timeout-merged.wav")
        FileManager.default.createFile(atPath: firstMicURL.path, contents: Data("mic".utf8))
        FileManager.default.createFile(atPath: finalMicURL.path, contents: Data("merged".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        let failedId = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedId,
            micAudioURL: firstMicURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized."
        ))
        try FileManager.default.removeItem(at: paths.failedQueue)
        try FileManager.default.createDirectory(at: paths.failedQueue, withIntermediateDirectories: true)

        XCTAssertFalse(manager.updateFailedTranscriptionAudio(
            id: failedId,
            micAudioURL: finalMicURL,
            systemAudioURL: nil
        ))

        let failed = try XCTUnwrap(manager.failedTranscriptions.first)
        XCTAssertEqual(failed.id, failedId)
        XCTAssertEqual(failed.micAudioURL, firstMicURL)
        XCTAssertNil(failed.systemAudioURL)
    }

    func testAddFailedTranscriptionRollsBackMemoryWhenPersistenceFails() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        let micURL = paths.audioCaptures.appendingPathComponent("safe-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        let manager = FailedTranscriptionManager(paths: paths)
        try FileManager.default.createDirectory(at: paths.failedQueue, withIntermediateDirectories: true)

        let didPersist = manager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )

        XCTAssertFalse(didPersist)
        XCTAssertTrue(manager.failedTranscriptions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    }

    func testInitKeepsMicOnlyMissingSystemAudioFailuresRetryable() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: paths.failedQueue.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let micURL = paths.audioCaptures.appendingPathComponent("missing-system-audio-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))

        let failure = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 10),
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "System audio is required to transcribe this meeting."
        )
        XCTAssertTrue(failure.isRetryable)
        try JSONEncoder.iso8601.encode([failure]).write(to: paths.failedQueue, options: .atomic)

        let manager = FailedTranscriptionManager(paths: paths)

        XCTAssertEqual(manager.failedTranscriptions, [failure])
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    }

    func testInitKeepsExhaustedRetryFailuresUntilUserDeletesThem() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: paths.failedQueue.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let micURL = paths.audioCaptures.appendingPathComponent("exhausted-retry-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))

        let failure = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 11),
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure",
            retryCount: 3
        )
        try JSONEncoder.iso8601.encode([failure]).write(to: paths.failedQueue, options: .atomic)

        let manager = FailedTranscriptionManager(paths: paths)

        XCTAssertEqual(manager.failedTranscriptions, [failure])
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    }

    func testFailedTranscriptionRetryabilityDoesNotOvermatchGenericMinimumLanguage() {
        let failure = FailedTranscription(
            micAudioURL: testRoot.appendingPathComponent("mic.wav"),
            systemAudioURL: nil,
            errorMessage: "Upload failed after at least one retry because the destination was unavailable."
        )

        XCTAssertTrue(failure.isRetryable)
    }

    func testFailedTranscriptionRetryabilityKeepsShortAudioPermanent() {
        let failure = FailedTranscription(
            micAudioURL: testRoot.appendingPathComponent("mic.wav"),
            systemAudioURL: nil,
            errorMessage: "Invalid audio data provided. Must be at least 1 second of 16kHz audio."
        )

        XCTAssertFalse(failure.isRetryable)
    }

    func testFailedTranscriptionRetryabilityKeepsUnusableMicrophonePermanent() {
        let failure = FailedTranscription(
            micAudioURL: testRoot.appendingPathComponent("mic.wav"),
            systemAudioURL: testRoot.appendingPathComponent("system.wav"),
            errorMessage: "Microphone audio was not usable. Open Transcripted Home to retry the saved meeting."
        )

        XCTAssertFalse(failure.isRetryable)
    }

    func testLoadHealsMissingMicAudioToMergedSibling() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        // The pre-merge mic WAV was deleted by a completed merge, but the app
        // died before the queue entry was repointed at the merged file.
        let missingMicURL = paths.audioCaptures.appendingPathComponent("meeting-mic.wav")
        let mergedSiblingURL = paths.audioCaptures.appendingPathComponent("meeting-mic_merged.wav")
        FileManager.default.createFile(atPath: mergedSiblingURL.path, contents: Data("merged".utf8))

        let entry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            micAudioURL: missingMicURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out"
        )
        try writeQueue([entry], to: paths)

        let manager = FailedTranscriptionManager(paths: paths)

        XCTAssertEqual(manager.failedTranscriptions.count, 1)
        XCTAssertEqual(manager.failedTranscriptions.first?.id, entry.id)
        XCTAssertEqual(manager.failedTranscriptions.first?.micAudioURL, mergedSiblingURL)

        // The heal must be durable, not just in-memory.
        let persisted = try JSONDecoder.iso8601.decode(
            [FailedTranscription].self,
            from: Data(contentsOf: paths.failedQueue)
        )
        XCTAssertEqual(persisted.first?.micAudioURL, mergedSiblingURL)
    }

    func testLoadKeepsEntryWithMicOnlyWhenSystemAudioIsMissing() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let micURL = paths.audioCaptures.appendingPathComponent("meeting-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        let missingSystemURL = paths.audioCaptures.appendingPathComponent("meeting-system.wav")

        let entry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            micAudioURL: micURL,
            systemAudioURL: missingSystemURL,
            errorMessage: "Recording stop timed out"
        )
        try writeQueue([entry], to: paths)

        let manager = FailedTranscriptionManager(paths: paths)

        XCTAssertEqual(manager.failedTranscriptions.count, 1)
        XCTAssertEqual(manager.failedTranscriptions.first?.micAudioURL, micURL)
        XCTAssertNil(manager.failedTranscriptions.first?.systemAudioURL)
    }

    func testLoadKeepsEntryWhenAudioRootIsUnavailableAndDoesNotRewriteQueue() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(
            at: paths.failedQueue.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let unavailableMicURL = paths.audioCaptures.appendingPathComponent("external-drive-mic.wav")
        let entry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            micAudioURL: unavailableMicURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )
        try JSONEncoder.iso8601.encode([entry]).write(to: paths.failedQueue, options: .atomic)
        let originalData = try Data(contentsOf: paths.failedQueue)

        let manager = FailedTranscriptionManager(paths: paths)

        XCTAssertEqual(manager.failedTranscriptions, [entry])
        XCTAssertEqual(try Data(contentsOf: paths.failedQueue), originalData)
    }

    func testLoadDoesNotStripSystemAudioWhenArchiveRootIsUnavailable() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: paths.failedQueue.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let micURL = paths.audioCaptures.appendingPathComponent("meeting-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        let unavailableSystemURL = paths.transcripts
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("Failed_Call_audio", isDirectory: true)
            .appendingPathComponent("system.wav")
        let entry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            micAudioURL: micURL,
            systemAudioURL: unavailableSystemURL,
            errorMessage: "Temporary transcription failure"
        )
        try JSONEncoder.iso8601.encode([entry]).write(to: paths.failedQueue, options: .atomic)
        let originalData = try Data(contentsOf: paths.failedQueue)

        let manager = FailedTranscriptionManager(paths: paths)

        XCTAssertEqual(manager.failedTranscriptions, [entry])
        XCTAssertEqual(manager.failedTranscriptions.first?.systemAudioURL, unavailableSystemURL)
        XCTAssertEqual(try Data(contentsOf: paths.failedQueue), originalData)
    }

    func testLoadRewritesRelocatedFailedAudioArchivePaths() throws {
        let paths = makePaths(root: testRoot)
        let currentArchiveDirectory = paths.transcripts
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("Failed_Customer_Call_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: currentArchiveDirectory, withIntermediateDirectories: true)
        let currentMicURL = currentArchiveDirectory.appendingPathComponent("microphone.wav")
        let currentSystemURL = currentArchiveDirectory.appendingPathComponent("system_audio.wav")
        FileManager.default.createFile(atPath: currentMicURL.path, contents: Data("mic".utf8))
        FileManager.default.createFile(atPath: currentSystemURL.path, contents: Data("system".utf8))

        let oldArchiveDirectory = testRoot
            .appendingPathComponent("old-library/meetings/audio/Failed_Customer_Call_audio", isDirectory: true)
        let entry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            micAudioURL: oldArchiveDirectory.appendingPathComponent("microphone.wav"),
            systemAudioURL: oldArchiveDirectory.appendingPathComponent("system_audio.wav"),
            errorMessage: "Temporary transcription failure"
        )
        try writeQueue([entry], to: paths)

        let manager = FailedTranscriptionManager(paths: paths)

        let healed = try XCTUnwrap(manager.failedTranscriptions.first)
        XCTAssertEqual(healed.id, entry.id)
        XCTAssertEqual(healed.micAudioURL, currentMicURL)
        XCTAssertEqual(healed.systemAudioURL, currentSystemURL)

        let persisted = try JSONDecoder.iso8601.decode(
            [FailedTranscription].self,
            from: Data(contentsOf: paths.failedQueue)
        )
        XCTAssertEqual(persisted.first?.micAudioURL, currentMicURL)
        XCTAssertEqual(persisted.first?.systemAudioURL, currentSystemURL)
    }

    func testLoadRepairsUnfinalizedWAVHeader() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let micURL = paths.audioCaptures.appendingPathComponent("meeting-mic.wav")
        try writeMonoWAV(to: micURL, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 9_600))
        try corruptHeaderSizes(at: micURL)
        XCTAssertEqual(try AVAudioFile(forReading: micURL).length, 0)

        let entry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Audio was preserved before quit"
        )
        try writeQueue([entry], to: paths)

        let manager = FailedTranscriptionManager(paths: paths)

        XCTAssertEqual(manager.failedTranscriptions.count, 1)
        XCTAssertEqual(try AVAudioFile(forReading: micURL).length, 9_600)
    }

    private func writeQueue(_ entries: [FailedTranscription], to paths: CoreStoragePaths) throws {
        try FileManager.default.createDirectory(
            at: paths.failedQueue.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder.iso8601.encode(entries).write(to: paths.failedQueue, options: .atomic)
    }

    private func writeMonoWAV(to url: URL, sampleRate: Double, samples: [Float]) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            channelData.update(from: baseAddress, count: samples.count)
        }
        try file.write(from: buffer)
        file.close()
    }

    private func corruptHeaderSizes(at url: URL) throws {
        let info = try WAVHeaderRepair.probe(at: url)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let headerOnlyRIFFSize = UInt32(info.dataSizeFieldOffset - 4)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: headerOnlyRIFFSize.littleEndian) { Data($0) })
        try handle.seek(toOffset: UInt64(info.dataSizeFieldOffset))
        try handle.write(contentsOf: Data([0, 0, 0, 0]))
    }

    private func makePaths(root: URL) -> CoreStoragePaths {
        CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

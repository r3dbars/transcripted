import Combine
import Foundation
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
extension FailedTranscriptionManagerTests {
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

    func testSystemOnlyDeleteFailsClosedWhenJournalIdentityIsAmbiguous() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        let placeholderURL = paths.audioCaptures.appendingPathComponent("system-only-placeholder.wav")
        let systemURL = paths.audioCaptures.appendingPathComponent("shared-system.wav")
        FileManager.default.createFile(atPath: placeholderURL.path, contents: Data("placeholder".utf8))
        FileManager.default.createFile(atPath: systemURL.path, contents: Data("system".utf8))
        var journalURLs: [URL] = []
        for index in 1...2 {
            let missingMicURL = paths.audioCaptures.appendingPathComponent("missing-mic-\(index).wav")
            let journalURL = paths.audioCaptures.appendingPathComponent("missing-mic-\(index).recording.json")
            let journal = MeetingRecordingJournalStore(directory: paths.audioCaptures)
            let session = journal.begin(primaryMicURL: missingMicURL)
            journal.recordSystemAudio(systemURL, session: session)
            journal.markFinalized(finalMicURL: nil, session: session)
            journal.flush()
            journalURLs.append(journalURL)
        }

        let manager = FailedTranscriptionManager(paths: paths)
        let failedID = UUID()
        XCTAssertTrue(manager.addFailedTranscription(
            id: failedID,
            micAudioURL: placeholderURL,
            systemAudioURL: systemURL,
            errorMessage: "Recording stop timed out before audio files were finalized."
        ))

        XCTAssertFalse(manager.deleteFailedTranscription(id: failedID))
        XCTAssertEqual(manager.failedTranscriptions.map(\.id), [failedID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: placeholderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(journalURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        let reloaded = FailedTranscriptionManager(paths: paths)
        XCTAssertEqual(reloaded.failedTranscriptions.map(\.id), [failedID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: placeholderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(journalURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
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

    func testDeleteDefersWhenAudioRootIsAlreadyUnavailable() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        let micURL = paths.audioCaptures.appendingPathComponent("offline-before-delete-mic.wav")
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
        try FileManager.default.removeItem(at: paths.audioCaptures)

        XCTAssertFalse(manager.deleteFailedTranscription(id: failedID))
        XCTAssertEqual(manager.failedTranscriptions.map(\.id), [failedID])
        let pendingDeletionURL = paths.failedQueue.deletingLastPathComponent()
            .appendingPathComponent(FailedTranscriptionManager.pendingDeletionFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDeletionURL.path))

        // Simulate the managed volume returning at the same canonical root.
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: micURL.path, contents: micData)
        let relaunched = FailedTranscriptionManager(paths: paths)

        XCTAssertTrue(relaunched.failedTranscriptions.isEmpty)
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
}

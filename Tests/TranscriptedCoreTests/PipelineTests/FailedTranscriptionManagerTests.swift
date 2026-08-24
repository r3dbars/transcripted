import AVFoundation
import Combine
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class FailedTranscriptionManagerTests: XCTestCase {
    var testRoot: URL!

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

    func testFailedTranscriptionRetryabilityOffersUnusableMicrophoneWhenSystemAudioSurvived() {
        // A broken microphone track does not make a meeting unrecoverable: the
        // current pipeline drops an unusable mic and transcribes system audio
        // alone. Builds that predated that fallback aborted the whole run, and
        // their persisted rows still carry this message — so treating the
        // message as permanent stranded perfectly good remote audio behind a
        // retry button the row never even drew.
        //
        // Note the error text itself tells the user to "Open Transcripted Home
        // to retry the saved meeting", which is only honest if the row offers
        // retry.
        let failure = FailedTranscription(
            micAudioURL: testRoot.appendingPathComponent("mic.wav"),
            systemAudioURL: testRoot.appendingPathComponent("system.wav"),
            errorMessage: "Microphone audio was not usable. Open Transcripted Home to retry the saved meeting."
        )

        XCTAssertTrue(failure.isRetryable)
    }

    func testFailedTranscriptionRetryabilityKeepsContentEmptyFailuresPermanent() {
        // The other half of the policy: when the audio genuinely holds nothing,
        // retrying can only spend inference time reproducing the same failure.
        for message in [
            "No speech detected",
            "Recording too short",
            "Invalid audio data provided. Must be at least 1 second of 16kHz audio."
        ] {
            let failure = FailedTranscription(
                micAudioURL: testRoot.appendingPathComponent("mic.wav"),
                systemAudioURL: testRoot.appendingPathComponent("system.wav"),
                errorMessage: message
            )
            XCTAssertFalse(failure.isRetryable, "\(message) should stay permanent")
        }
    }

    func testPipelineErrorKindSeparatesRecoverableSourcesFromEmptyContent() {
        for kind in [
            PipelineErrorKind.emptyAudioFile,
            .microphoneAudioUnusable,
            .invalidAudioFormat,
            .missingSystemAudio
        ] {
            XCTAssertTrue(
                kind.describesRecoverableSource,
                "\(kind.rawValue) describes one capture source breaking, which the pipeline can work around"
            )
        }

        for kind in [PipelineErrorKind.noSpeechDetected, .recordingTooShort] {
            XCTAssertFalse(
                kind.describesRecoverableSource,
                "\(kind.rawValue) means the audio itself holds nothing to transcribe"
            )
        }
    }

    func testFailedTranscriptionRetryabilityUsesTypedUnusableMicrophoneKind() {
        let failure = FailedTranscription(
            micAudioURL: testRoot.appendingPathComponent("mic.wav"),
            systemAudioURL: testRoot.appendingPathComponent("system.wav"),
            errorMessage: "anything at all",
            errorKind: .microphoneAudioUnusable
        )

        XCTAssertTrue(failure.isRetryable, "the typed kind should reach the same verdict as the legacy message")
    }

    func testFailedTranscriptionErrorKindTakesPrecedenceOverLegacyMessageMatching() {
        // The message text alone would legacy-match "recording too short" (permanent),
        // but a typed errorKind of .saveFailed (retryable) must win — proving the
        // typed field is actually consulted first, not just carried as inert metadata.
        let typed = FailedTranscription(
            micAudioURL: testRoot.appendingPathComponent("mic.wav"),
            systemAudioURL: testRoot.appendingPathComponent("system.wav"),
            errorMessage: "Recording too short",
            errorKind: .saveFailed
        )
        XCTAssertTrue(typed.isRetryable, "typed errorKind should take precedence over legacy message matching")

        let legacy = FailedTranscription(
            micAudioURL: testRoot.appendingPathComponent("mic.wav"),
            systemAudioURL: testRoot.appendingPathComponent("system.wav"),
            errorMessage: "Recording too short",
            errorKind: nil
        )
        XCTAssertFalse(legacy.isRetryable, "without a typed kind, the same message should still fall back to legacy matching")
    }

    func testFailedTranscriptionDecodesLegacyJSONMissingErrorKindField() throws {
        // Simulates a `FailedTranscription` persisted before `errorKind` existed:
        // encode a current entry, then strip the "errorKind" key entirely (not just
        // null it out) before decoding, matching what's actually on disk for old rows.
        let modern = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            micAudioURL: testRoot.appendingPathComponent("mic.wav"),
            systemAudioURL: testRoot.appendingPathComponent("system.wav"),
            errorMessage: "No speech detected",
            errorKind: .noSpeechDetected
        )
        let encoded = try JSONEncoder.iso8601.encode(modern)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            XCTFail("expected a JSON object")
            return
        }
        XCTAssertNotNil(object["errorKind"], "precondition: the modern encoding should include errorKind")
        object.removeValue(forKey: "errorKind")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder.iso8601.decode(FailedTranscription.self, from: legacyData)

        XCTAssertNil(decoded.errorKind, "legacy rows without the errorKind key must decode to nil, not fail or default")
        XCTAssertEqual(decoded.errorMessage, "No speech detected")
        XCTAssertFalse(decoded.isRetryable, "decoded legacy entry should still classify via the string fallback")
    }

    func testFailedTranscriptionManagerLoadsLegacyQueueFileWithoutErrorKind() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let micURL = paths.audioCaptures.appendingPathComponent("legacy-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))

        let entry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 5_000),
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Empty audio file",
            errorKind: .emptyAudioFile
        )
        let encoded = try JSONEncoder.iso8601.encode([entry])
        guard var array = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]] else {
            XCTFail("expected a JSON array")
            return
        }
        array[0].removeValue(forKey: "errorKind")
        let legacyQueueData = try JSONSerialization.data(withJSONObject: array)

        try FileManager.default.createDirectory(
            at: paths.failedQueue.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try legacyQueueData.write(to: paths.failedQueue, options: .atomic)

        let manager = FailedTranscriptionManager(paths: paths)

        XCTAssertEqual(manager.failedTranscriptions.count, 1)
        XCTAssertNil(manager.failedTranscriptions.first?.errorKind)
        XCTAssertEqual(manager.failedTranscriptions.first?.errorMessage, "Empty audio file")
        // "Empty audio file" names one source that produced no samples, not a
        // whole recording with nothing in it, so the row stays offerable and
        // the signal probe decides whether the surviving file is worth a run.
        XCTAssertTrue(manager.failedTranscriptions.first?.isRetryable ?? false)
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

    func testLoadKeepsRelocatedMicOnlyQueueRowsDurableWhenOptionalSystemAudioIsMissing() throws {
        let paths = makePaths(root: testRoot)
        let oldArchiveDirectory = testRoot
            .appendingPathComponent("old-library/meetings/audio/Failed_Customer_Call_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: oldArchiveDirectory, withIntermediateDirectories: true)
        let oldMicURL = oldArchiveDirectory.appendingPathComponent("microphone.wav")
        FileManager.default.createFile(atPath: oldMicURL.path, contents: Data("old mic".utf8))

        let relocatedEntry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            micAudioURL: oldMicURL,
            systemAudioURL: oldArchiveDirectory.appendingPathComponent("missing-system.wav"),
            errorMessage: "Temporary transcription failure"
        )
        try writeQueue([relocatedEntry], to: paths)

        let manager = FailedTranscriptionManager(paths: paths)
        XCTAssertTrue(
            manager.failedTranscriptions.isEmpty,
            "audio outside the active library must not be exposed for retry or deletion"
        )

        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        let currentMicURL = paths.audioCaptures.appendingPathComponent("current.wav")
        FileManager.default.createFile(atPath: currentMicURL.path, contents: Data("current mic".utf8))
        XCTAssertTrue(manager.addFailedTranscription(
            micAudioURL: currentMicURL,
            systemAudioURL: nil,
            errorMessage: "Current failure"
        ))

        let persisted = try JSONDecoder.iso8601.decode(
            [FailedTranscription].self,
            from: Data(contentsOf: paths.failedQueue)
        )
        XCTAssertEqual(Set(persisted.map(\.id)), Set([relocatedEntry.id, manager.failedTranscriptions[0].id]))
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

    func makePaths(root: URL) -> CoreStoragePaths {
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

extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

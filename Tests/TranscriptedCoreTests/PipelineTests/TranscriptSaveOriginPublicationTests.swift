import Combine
import Foundation
import XCTest
@testable import TranscriptedCore

@MainActor
final class TranscriptSaveOriginPublicationTests: XCTestCase {
    func testSaveOriginIsCurrentInsideEverySynchronousStatusPublication() throws {
        guard ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1",
              ProcessInfo.processInfo.environment["TRANSCRIPTED_LAB_KNOBS_FILE"] == nil else {
            XCTFail("This fixture requires disabled file logging and no external lab-knob file")
            return
        }
        let fixture = try SaveOriginPublicationFixture()
        defer {
            do { try fixture.cleanup() }
            catch { XCTFail("Owned save-origin fixture cleanup failed") }
        }
        do {
            let manager = fixture.makeManager()
            let transcript = try fixture.transcript()
            var expectedStatus: DisplayStatus = .transcriptSaved
            var expectedOrigin: TranscriptSaveOrigin? = .pipeline
            var statuses: [DisplayStatus] = []
            var origins: [TranscriptSaveOrigin?] = []
            let subscription = manager.$displayStatus.dropFirst().sink { status in
                // @Published emits before its stored status changes. Inspect
                // the emitted value and the origin at that exact callback.
                XCTAssertEqual(status, expectedStatus)
                XCTAssertEqual(manager.lastTranscriptSaveOrigin, expectedOrigin,
                               "The origin must already describe the emitted status")
                statuses.append(status)
                origins.append(manager.lastTranscriptSaveOrigin)
            }
            defer { subscription.cancel() }

            manager.publishTranscriptSaved(from: transcript, taskId: UUID())
            XCTAssertEqual(statuses.count, 1, "Pipeline publication is synchronous")

            expectedOrigin = .speakerReview
            manager.publishSpeakerNamesSaved()
            XCTAssertEqual(statuses.count, 2, "Review publication is synchronous even after a pipeline save")

            expectedStatus = .idle
            expectedOrigin = nil
            manager.publishNonFailureStatus(.idle)
            XCTAssertEqual(statuses.count, 3, "Idle clears the previous origin before publication")

            expectedStatus = .transcriptSaved
            expectedOrigin = .pipeline
            manager.publishTranscriptSaved(from: transcript, taskId: nil)
            XCTAssertEqual(statuses.count, 4, "A direct pipeline save without a task ID still has pipeline origin")

            expectedStatus = .failed(message: "Synthetic failure")
            expectedOrigin = nil
            manager.publishFailure(displayMessage: "Synthetic failure", diagnosticMessage: "Synthetic diagnostic")
            XCTAssertEqual(statuses.count, 5, "Failure clears the preceding pipeline origin")

            expectedStatus = .transcriptSaved
            expectedOrigin = .speakerReview
            manager.publishSpeakerNamesSaved()
            XCTAssertEqual(statuses.count, 6, "Review origin replaces the failure state")

            expectedOrigin = nil
            manager.publishNonFailureStatus(.transcriptSaved)
            XCTAssertEqual(statuses.count, 7, "A save with unknown provenance cannot inherit review origin")
            XCTAssertEqual(origins, [.pipeline, .speakerReview, nil, .pipeline, nil, .speakerReview, nil])
        }
    }
}

@MainActor
private final class SaveOriginPublicationFixture {
    private let parent: URL
    private let root: URL
    private let paths: CoreStoragePaths

    init() throws {
        parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        root = parent.appendingPathComponent("SaveOriginPublication-\(UUID().uuidString)", isDirectory: true)
        paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("transcripts"),
            speakerDB: root.appendingPathComponent("fixture-speakers.sqlite"),
            statsDB: root.appendingPathComponent("stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed.json"),
            speakerClips: root.appendingPathComponent("clips"),
            audioCaptures: root.appendingPathComponent("audio"),
            logs: root.appendingPathComponent("logs")
        )
        for directory in [paths.transcripts, paths.speakerClips, paths.audioCaptures, paths.logs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func makeManager() -> TranscriptionTaskManager {
        let speakers = SpeakerDatabase(path: paths.speakerDB.path, adoptCanonicalModelIdentity: false)
        _ = speakers.allSpeakers() // Drain its owned-database initialization before teardown is possible.
        return TranscriptionTaskManager(
            failedTranscriptionManager: FailedTranscriptionManager(paths: paths),
            speechToText: MetadataStubSpeechToTextEngine(),
            diarization: MetadataStubDiarizationEngine(),
            speakerStore: speakers,
            speakerClipsDirectory: paths.speakerClips,
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips],
            retainedAudioDirectory: paths.transcripts.appendingPathComponent("audio"),
            retainedAudioDirectoryProvider: { [paths] in paths.transcripts.appendingPathComponent("audio") },
            transcriptDirectoryProvider: { [paths] in paths.transcripts },
            transcriptFormatOptionsProvider: { TranscriptFormatOptions() },
            statsStore: MetadataCapturingStatsStore(),
            notifier: nil
        )
    }

    func transcript() throws -> URL {
        let url = paths.transcripts.appendingPathComponent("Synthetic.md")
        let markdown = "---\ntranscript_id: 00000000-0000-0000-0000-000000000001\ntitle: Synthetic\ndate: 2026-11-10\nduration: 00:01\n---\n\nSynthetic fixture.\n"
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func cleanup() throws {
        let prefix = "SaveOriginPublication-"
        let leaf = root.lastPathComponent
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard leaf.hasPrefix(prefix), UUID(uuidString: String(leaf.dropFirst(prefix.count))) != nil,
              canonical == root.standardizedFileURL, canonical.deletingLastPathComponent() == parent,
              values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: root)
    }
}

import XCTest
import Combine
import AVFoundation
import FluidAudio
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class TranscriptionTaskManagerMetadataTests: XCTestCase {
    var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testPopulateSavedMetadataReadsLargeFrontmatterBeyondInitialChunk() throws {
        let manager = makeManager()
        let transcriptURL = tempDirectory.appendingPathComponent("Call_2026-04-22.md")

        let filler = (0..<180)
            .map { "padding_\($0): \"\(String(repeating: "x", count: 20))\"" }
            .joined(separator: "\n")
        let content = """
        ---
        date: 2026-04-22
        \(filler)
        title: "Quarterly Planning Review"
        duration: "42:17"
        mic_speakers: 2
        system_speakers: 3
        ---

        # Meeting Recording
        """
        try content.write(to: transcriptURL, atomically: true, encoding: .utf8)

        manager.populateSavedMetadata(from: transcriptURL)

        XCTAssertEqual(manager.lastSavedTitle, "Quarterly Planning Review")
        XCTAssertEqual(manager.lastSavedDuration, "42:17")
        XCTAssertEqual(manager.lastSavedSpeakerCount, 5)
    }

    func testResolvedRetainedAudioDirectoryFollowsProvider() {
        var providerCallCount = 0
        var nextDirectory = tempDirectory.appendingPathComponent("first")
        let manager = makeManager(retainedAudioDirectoryProvider: {
            providerCallCount += 1
            return nextDirectory
        })

        XCTAssertEqual(manager.resolvedRetainedAudioDirectory(), tempDirectory.appendingPathComponent("first"))
        XCTAssertEqual(providerCallCount, 1, "resolver should call provider on each lookup")

        nextDirectory = tempDirectory.appendingPathComponent("second")
        XCTAssertEqual(manager.resolvedRetainedAudioDirectory(), tempDirectory.appendingPathComponent("second"),
                       "resolver should reflect provider changes between calls (e.g. user moves capture library)")
        XCTAssertEqual(providerCallCount, 2)
    }

    func testResolvedRetainedAudioDirectoryFallsBackToStaticValue() {
        let staticDirectory = tempDirectory.appendingPathComponent("static")
        let manager = makeManager(retainedAudioDirectory: staticDirectory)

        XCTAssertEqual(manager.resolvedRetainedAudioDirectory(), staticDirectory,
                       "embedders that pass only the static value should still get a valid resolver result")
    }

    func testPublishTranscriptSavedDoesNotStayFinishingWhenSpeakerReviewIsPending() throws {
        let manager = makeManager()
        let transcriptURL = tempDirectory.appendingPathComponent("Customer_Call.md")
        try """
        ---
        transcript_id: "00000000-0000-0000-0000-000000000321"
        title: "Customer Call"
        duration: "10:03"
        mic_speakers: 1
        system_speakers: 2
        ---

        # Meeting Recording
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        manager.displayStatus = .finishing
        manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: transcriptURL,
            transcriptId: UUID(),
            systemAudioURL: tempDirectory.appendingPathComponent("system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        )

        manager.publishTranscriptSaved(from: transcriptURL)

        XCTAssertEqual(manager.displayStatus, .transcriptSaved)
        XCTAssertEqual(manager.lastSavedTranscriptId, UUID(uuidString: "00000000-0000-0000-0000-000000000321"))
        XCTAssertEqual(manager.lastSavedTitle, "Customer Call")
        XCTAssertEqual(manager.lastSavedDuration, "10:03")
        XCTAssertEqual(manager.lastSavedSpeakerCount, 3)
    }

    func testSavedTranscriptOwnerSurvivesSpeakerReviewRewrite() throws {
        let manager = makeManager()
        let taskId = UUID()
        let transcriptId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Customer_Call.md")
        try """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        title: "Customer Call"
        duration: "10:03"
        mic_speakers: 1
        system_speakers: 2
        ---

        # Meeting Recording
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        manager.publishTranscriptSaved(from: transcriptURL, taskId: taskId)
        manager.populateSavedMetadata(from: transcriptURL)

        XCTAssertEqual(manager.lastSavedTranscriptTaskId, taskId)
    }

    func testSavedTranscriptOwnerSurvivesInterleavedSpeakerReviewRewrite() throws {
        let manager = makeManager()
        let firstTaskId = UUID()
        let secondTaskId = UUID()
        let firstTranscriptId = UUID()
        let secondTranscriptId = UUID()
        let firstURL = tempDirectory.appendingPathComponent("First_Call.md")
        let firstRenamedURL = tempDirectory.appendingPathComponent("First_Call_Named.md")
        let secondURL = tempDirectory.appendingPathComponent("Second_Call.md")

        try transcriptContent(id: firstTranscriptId, title: "First Call")
            .write(to: firstURL, atomically: true, encoding: .utf8)
        try transcriptContent(id: firstTranscriptId, title: "First Call")
            .write(to: firstRenamedURL, atomically: true, encoding: .utf8)
        try transcriptContent(id: secondTranscriptId, title: "Second Call")
            .write(to: secondURL, atomically: true, encoding: .utf8)

        manager.publishTranscriptSaved(from: firstURL, taskId: firstTaskId)
        manager.publishTranscriptSaved(from: secondURL, taskId: secondTaskId)
        manager.populateSavedMetadata(from: firstRenamedURL)

        XCTAssertEqual(manager.lastSavedTranscriptId, firstTranscriptId)
        XCTAssertEqual(manager.lastSavedTranscriptTaskId, firstTaskId)
    }

    func testPendingSpeakerNamingReviewTracksLastSavedTranscriptAcrossRename() throws {
        let manager = makeManager()
        let taskId = UUID()
        let transcriptId = UUID()
        let originalURL = tempDirectory.appendingPathComponent("Customer_Call.md")
        let renamedURL = tempDirectory.appendingPathComponent("Customer_Call_Named.md")
        let content = """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        title: "Customer Call"
        duration: "10:03"
        mic_speakers: 1
        system_speakers: 2
        ---

        # Meeting Recording
        """
        try content.write(to: originalURL, atomically: true, encoding: .utf8)
        try content.write(to: renamedURL, atomically: true, encoding: .utf8)

        manager.publishTranscriptSaved(from: originalURL, taskId: taskId)
        manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: originalURL,
            transcriptId: transcriptId,
            systemAudioURL: tempDirectory.appendingPathComponent("system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        )
        manager.populateSavedMetadata(from: renamedURL)

        XCTAssertTrue(manager.hasPendingSpeakerNamingReviewForLastSavedTranscript())
        XCTAssertEqual(manager.lastSavedTranscriptTaskId, taskId)
    }

    func testDeferPendingSpeakerNamingReviewCompletesWithReviewLater() {
        let manager = makeManager()
        var completedUpdates: [SpeakerNameUpdate]?
        manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: tempDirectory.appendingPathComponent("call.md"),
            transcriptId: UUID(),
            systemAudioURL: tempDirectory.appendingPathComponent("system.wav"),
            micAudioURL: nil,
            onComplete: { updates in
                completedUpdates = updates
            }
        )

        XCTAssertTrue(manager.deferPendingSpeakerNamingReview(reason: "queued_transcription"))
        XCTAssertEqual(completedUpdates?.count, 0)
        XCTAssertNil(manager.speakerNamingRequest)
        XCTAssertFalse(manager.deferPendingSpeakerNamingReview(reason: "queued_transcription"))
    }

    func testQueuedSpeakerNamingRequestDoesNotReplaceActiveReview() {
        let manager = makeManager()
        let firstId = UUID()
        let secondId = UUID()

        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [],
            transcriptURL: tempDirectory.appendingPathComponent("first.md"),
            transcriptId: firstId,
            systemAudioURL: tempDirectory.appendingPathComponent("first-system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        ))
        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [],
            transcriptURL: tempDirectory.appendingPathComponent("second.md"),
            transcriptId: secondId,
            systemAudioURL: tempDirectory.appendingPathComponent("second-system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        ))

        XCTAssertEqual(manager.speakerNamingRequest?.transcriptId, firstId)
        XCTAssertEqual(manager.pendingSpeakerNamingRequests.map(\.transcriptId), [secondId])
    }

    func testDuplicateSpeakerNamingRequestsAreIgnoredForActiveAndQueuedTranscripts() {
        let manager = makeManager()
        let firstId = UUID()
        let secondId = UUID()

        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [],
            transcriptURL: tempDirectory.appendingPathComponent("first.md"),
            transcriptId: firstId,
            systemAudioURL: tempDirectory.appendingPathComponent("first-system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        ))
        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [],
            transcriptURL: tempDirectory.appendingPathComponent("first-duplicate.md"),
            transcriptId: firstId,
            systemAudioURL: tempDirectory.appendingPathComponent("first-duplicate-system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        ))
        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [],
            transcriptURL: tempDirectory.appendingPathComponent("second.md"),
            transcriptId: secondId,
            systemAudioURL: tempDirectory.appendingPathComponent("second-system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        ))
        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [],
            transcriptURL: tempDirectory.appendingPathComponent("second-duplicate.md"),
            transcriptId: secondId,
            systemAudioURL: tempDirectory.appendingPathComponent("second-duplicate-system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        ))

        XCTAssertEqual(manager.speakerNamingRequest?.transcriptId, firstId)
        XCTAssertEqual(manager.pendingSpeakerNamingRequests.map(\.transcriptId), [secondId])
    }

    func testClearCompletedSpeakerNamingRequestClearsActiveReviewAndPromotesNext() {
        let manager = makeManager()
        let firstId = UUID()
        let secondId = UUID()

        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [],
            transcriptURL: tempDirectory.appendingPathComponent("first.md"),
            transcriptId: firstId,
            systemAudioURL: tempDirectory.appendingPathComponent("first-system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        ))
        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [],
            transcriptURL: tempDirectory.appendingPathComponent("second.md"),
            transcriptId: secondId,
            systemAudioURL: tempDirectory.appendingPathComponent("second-system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        ))

        manager.clearCompletedSpeakerNamingRequest(transcriptId: firstId)

        XCTAssertEqual(manager.speakerNamingRequest?.transcriptId, secondId)
        XCTAssertTrue(manager.pendingSpeakerNamingRequests.isEmpty)
    }

    func testCancelSpeakerNamingRequestCleansArtifactsAndPromotesNext() throws {
        let manager = makeManager()
        let firstId = UUID()
        let secondId = UUID()
        let micURL = tempDirectory.appendingPathComponent("audio/first-mic.wav")
        let systemURL = tempDirectory.appendingPathComponent("audio/first-system.wav")
        let clipURL = tempDirectory.appendingPathComponent("speaker_clips/first-clip.wav")
        try Data("mic".utf8).write(to: micURL)
        try Data("system".utf8).write(to: systemURL)
        try Data("clip".utf8).write(to: clipURL)

        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [
                SpeakerNamingEntry(
                    id: UUID(),
                    diarizerSpeakerId: "1",
                    clipURL: clipURL,
                    sampleText: "hello",
                    currentName: nil,
                    matchSimilarity: nil,
                    needsNaming: true,
                    needsConfirmation: false
                )
            ],
            transcriptURL: tempDirectory.appendingPathComponent("first.md"),
            transcriptId: firstId,
            systemAudioURL: systemURL,
            micAudioURL: micURL,
            shouldRemoveTemporaryAudioOnCleanup: true,
            onComplete: { _ in }
        ))
        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [],
            transcriptURL: tempDirectory.appendingPathComponent("second.md"),
            transcriptId: secondId,
            systemAudioURL: tempDirectory.appendingPathComponent("second-system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        ))

        manager.cancelSpeakerNamingRequest(transcriptId: firstId)

        XCTAssertEqual(manager.speakerNamingRequest?.transcriptId, secondId)
        XCTAssertTrue(manager.pendingSpeakerNamingRequests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clipURL.path))
    }

    func testStatusResetClearsSavedVisualWhileSpeakerReviewPendingButKeepsMetadata() async throws {
        let manager = makeManager()
        let transcriptURL = tempDirectory.appendingPathComponent("Customer_Call.md")
        try """
        ---
        transcript_id: "00000000-0000-0000-0000-000000000654"
        title: "Customer Call"
        duration: "12:34"
        mic_speakers: 1
        system_speakers: 1
        ---

        # Meeting Recording
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: transcriptURL,
            transcriptId: UUID(),
            systemAudioURL: tempDirectory.appendingPathComponent("system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        )

        manager.publishTranscriptSaved(from: transcriptURL)
        manager.scheduleStatusReset(delay: 0)

        try await waitUntil {
            if case .idle = manager.displayStatus { return true }
            return false
        }
        XCTAssertEqual(manager.lastSavedTranscriptId, UUID(uuidString: "00000000-0000-0000-0000-000000000654"))
        XCTAssertEqual(manager.lastSavedTitle, "Customer Call")
        XCTAssertNotNil(manager.speakerNamingRequest)
    }

    func testTranscriptionTaskCarriesCalendarMeetingTitle() {
        let task = TranscriptionTask(
            micURL: tempDirectory.appendingPathComponent("mic.wav"),
            systemURL: tempDirectory.appendingPathComponent("system.wav"),
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Customer Discovery Sync"
        )

        XCTAssertEqual(task.meetingTitle, "Customer Discovery Sync")
    }

    func testTranscriptFormatterWritesCalendarMeetingTitle() {
        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(
                    start: 0,
                    end: 2,
                    channel: 1,
                    speakerId: 0,
                    persistentSpeakerId: nil,
                    matchSimilarity: nil,
                    transcript: "Thanks for joining."
                )
            ],
            duration: 2,
            processingTime: 0.5
        )

        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            transcriptId: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            date: Date(timeIntervalSince1970: 0),
            meetingTitle: "Customer Discovery Sync"
        )

        XCTAssertTrue(markdown.contains("title: \"Customer Discovery Sync\""))
    }

    func testTranscriptFormatterUsesExplicitFormatOptionsForSourcesAndObsidianMetadata() throws {
        let originalObsidianDefault = UserDefaults.standard.object(forKey: "enableObsidianFormat")
        defer {
            if let originalObsidianDefault {
                UserDefaults.standard.set(originalObsidianDefault, forKey: "enableObsidianFormat")
            } else {
                UserDefaults.standard.removeObject(forKey: "enableObsidianFormat")
            }
        }
        UserDefaults.standard.set(true, forKey: "enableObsidianFormat")

        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(
                    start: 0,
                    end: 2,
                    channel: 1,
                    speakerId: 0,
                    persistentSpeakerId: nil,
                    matchSimilarity: nil,
                    transcript: "Imported meeting audio."
                )
            ],
            duration: 2,
            processingTime: 0.5
        )

        let defaultMarkdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            transcriptId: UUID(),
            date: Date(timeIntervalSince1970: 0),
            formatOptions: TranscriptFormatOptions(audioSources: [.systemAudio])
        )
        let obsidianMarkdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            transcriptId: UUID(),
            date: Date(timeIntervalSince1970: 0),
            formatOptions: TranscriptFormatOptions(
                audioSources: [.systemAudio],
                includeObsidianMetadata: true
            )
        )

        XCTAssertTrue(defaultMarkdown.contains("sources: [system_audio]"))
        XCTAssertFalse(defaultMarkdown.contains("### Microphone"), "system-only imports should not claim a microphone source")
        XCTAssertFalse(defaultMarkdown.contains("\ntags:"), "Core formatting should not read UserDefaults directly")
        XCTAssertTrue(obsidianMarkdown.contains("\ntags:"), "embedders can still opt into Obsidian metadata explicitly")
    }

    func makeManager(
        speechToText: (any SpeechToTextEngine)? = nil,
        diarization: (any DiarizationEngine)? = nil,
        retainedAudioDirectory: URL? = nil,
        retainedAudioDirectoryProvider: (() -> URL?)? = nil,
        statsStore: (any StatsStore)? = nil,
        failedQueueURL: URL? = nil
    ) -> TranscriptionTaskManager {
        let paths = CoreStoragePaths(
            transcripts: tempDirectory.appendingPathComponent("transcripts"),
            speakerDB: tempDirectory.appendingPathComponent("speakers.sqlite"),
            statsDB: tempDirectory.appendingPathComponent("stats.sqlite"),
            failedQueue: failedQueueURL ?? tempDirectory.appendingPathComponent("failed_transcriptions.json"),
            speakerClips: tempDirectory.appendingPathComponent("speaker_clips"),
            audioCaptures: tempDirectory.appendingPathComponent("audio"),
            logs: tempDirectory.appendingPathComponent("logs")
        )

        try? FileManager.default.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.speakerClips, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)

        let resolvedSpeechToText = speechToText ?? MetadataStubSpeechToTextEngine()
        let resolvedDiarization = diarization ?? MetadataStubDiarizationEngine()

        return TranscriptionTaskManager(
            failedTranscriptionManager: FailedTranscriptionManager(paths: paths),
            speechToText: resolvedSpeechToText,
            diarization: resolvedDiarization,
            speakerStore: SpeakerDatabase(path: paths.speakerDB.path),
            speakerClipsDirectory: paths.speakerClips,
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips],
            retainedAudioDirectory: retainedAudioDirectory,
            retainedAudioDirectoryProvider: retainedAudioDirectoryProvider,
            statsStore: statsStore
        )
    }

    func transcriptContent(id: UUID, title: String) -> String {
        """
        ---
        transcript_id: "\(id.uuidString)"
        title: "\(title)"
        duration: "10:03"
        mic_speakers: 1
        system_speakers: 2
        ---

        # Meeting Recording
        """
    }

    func writeMonoWAV(
        to url: URL,
        duration: TimeInterval,
        sampleRate: Double = 16_000,
        amplitude: Float = 0.25
    ) throws {
        let frameCount = Int(duration * sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return XCTFail("Failed to create test audio format")
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return XCTFail("Failed to create test audio buffer")
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        if let channelData = buffer.floatChannelData?[0] {
            for index in 0..<frameCount {
                channelData[index] = amplitude
            }
        }

        try file.write(from: buffer)
    }

    func singleSpeakerSegments(duration: TimeInterval = 2.0) -> [SpeakerSegment] {
        [
            SpeakerSegment(
                speakerId: 1,
                startTime: 0,
                endTime: duration,
                embedding: [Float](repeating: 0.42, count: 256),
                qualityScore: 0.95
            )
        ]
    }

    func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    func localDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            timeZone: .current,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))!
    }

    func frontmatterDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func frontmatterTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}


@available(macOS 14.0, *)
final class MetadataCapturingStatsStore: StatsStore {
    private let lock = NSLock()
    private var sessions: [RecordingMetadata] = []

    var recordedSessions: [RecordingMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return sessions
    }

    func recordSession(_ metadata: RecordingMetadata) {
        lock.lock()
        sessions.append(metadata)
        lock.unlock()
    }

    func getTotalRecordingsCount() -> Int {
        recordedSessions.count
    }

    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] {
        recordedSessions.filter { $0.date >= startDate && $0.date <= endDate }
    }

    func recordingExists(transcriptPath: String) -> Bool {
        recordedSessions.contains { $0.transcriptPath == transcriptPath }
    }
}

@available(macOS 14.0, *)
final class CancellingOnRecordStatsStore: StatsStore {
    private let base = MetadataCapturingStatsStore()
    private let lock = NSLock()
    private var didCallOnFirstRecord = false
    var onFirstRecord: (() -> Void)?

    var recordedSessions: [RecordingMetadata] {
        base.recordedSessions
    }

    func recordSession(_ metadata: RecordingMetadata) {
        base.recordSession(metadata)

        let callback: (() -> Void)?
        lock.lock()
        if didCallOnFirstRecord {
            callback = nil
        } else {
            didCallOnFirstRecord = true
            callback = onFirstRecord
        }
        lock.unlock()
        callback?()
    }

    func getTotalRecordingsCount() -> Int {
        base.getTotalRecordingsCount()
    }

    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] {
        base.getRecordings(from: startDate, to: endDate)
    }

    func recordingExists(transcriptPath: String) -> Bool {
        base.recordingExists(transcriptPath: transcriptPath)
    }
}

@available(macOS 14.0, *)
@MainActor
final class MetadataStubSpeechToTextEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool
    var initializeCallCount = 0
    private let transcript: String
    private let transcribeError: Error?

    init(isReady: Bool = true, transcript: String = "", transcribeError: Error? = nil) {
        self.isReady = isReady
        self.transcript = transcript
        self.transcribeError = transcribeError
    }

    func initialize() async {
        initializeCallCount += 1
        isReady = true
    }
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        if let transcribeError {
            throw transcribeError
        }
        return transcript
    }
    func cleanup() {
        isReady = false
    }
}

@available(macOS 14.0, *)
@MainActor
final class BlockingMetadataStubSpeechToTextEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    private(set) var didStart = false
    private(set) var didReturn = false
    private(set) var sawCancellation = false
    private var shouldRelease = false
    private let transcript: String

    init(transcript: String) {
        self.transcript = transcript
    }

    func initialize() async {
        isReady = true
    }

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        didStart = true
        while !shouldRelease {
            if Task.isCancelled {
                sawCancellation = true
                throw CancellationError()
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        didReturn = true
        return transcript
    }

    func release() {
        shouldRelease = true
    }

    func cleanup() {
        isReady = false
    }
}

@available(macOS 14.0, *)
@MainActor
final class MetadataStubDiarizationEngine: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool
    var initializeCallCount = 0
    private let segments: [SpeakerSegment]

    init(isReady: Bool = true, segments: [SpeakerSegment] = []) {
        self.isReady = isReady
        self.segments = segments
    }

    func initialize() async {
        initializeCallCount += 1
        isReady = true
    }
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] { segments }
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] { segments }
    func cleanup() {
        isReady = false
    }
}

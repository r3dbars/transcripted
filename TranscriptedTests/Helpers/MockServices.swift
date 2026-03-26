import Foundation
import Combine
@testable import Transcripted

// MARK: - Mock Speaker Store

@available(macOS 14.0, *)
final class MockSpeakerStore: SpeakerStore {
    var speakers: [SpeakerProfile] = []

    // Call tracking
    var matchSpeakerCallCount = 0
    var addOrUpdateCallCount = 0
    var setDisplayNameCallCount = 0
    var deleteCallCount = 0
    var mergeProfilesCallCount = 0
    var mergeByNameCallCount = 0
    var mergeDuplicatesCallCount = 0
    var pruneCallCount = 0
    var resetDisputeCallCount = 0
    var findByNameCallCount = 0

    // Argument capture
    var lastMatchEmbedding: [Float]?
    var lastMatchThreshold: Double?
    var lastSetDisplayNameId: UUID?
    var lastSetDisplayNameName: String?
    var lastSetDisplayNameSource: String?
    var lastDeleteId: UUID?
    var lastMergeSourceId: UUID?
    var lastMergeTargetId: UUID?
    var lastResetDisputeId: UUID?
    var lastFindByNameQuery: String?

    // Configurable return values
    var matchResult: SpeakerMatchResult?
    var addOrUpdateResult: SpeakerProfile?
    var findByNameResult: [SpeakerProfile] = []

    func matchSpeaker(embedding: [Float], threshold: Double) -> SpeakerMatchResult? {
        matchSpeakerCallCount += 1
        lastMatchEmbedding = embedding
        lastMatchThreshold = threshold
        return matchResult
    }

    func addOrUpdateSpeaker(embedding: [Float], existingId: UUID?) -> SpeakerProfile {
        addOrUpdateCallCount += 1
        if let result = addOrUpdateResult { return result }
        let profile = SpeakerProfile.mock(embedding: embedding)
        speakers.append(profile)
        return profile
    }

    func getSpeaker(id: UUID) -> SpeakerProfile? {
        speakers.first { $0.id == id }
    }

    func allSpeakers() -> [SpeakerProfile] {
        speakers
    }

    func setDisplayName(id: UUID, name: String, source: String) {
        setDisplayNameCallCount += 1
        lastSetDisplayNameId = id
        lastSetDisplayNameName = name
        lastSetDisplayNameSource = source
        if let idx = speakers.firstIndex(where: { $0.id == id }) {
            speakers[idx].displayName = name
            speakers[idx].nameSource = source
        }
    }

    func deleteSpeaker(id: UUID) {
        deleteCallCount += 1
        lastDeleteId = id
        speakers.removeAll { $0.id == id }
    }

    func mergeProfiles(sourceId: UUID, into targetId: UUID) {
        mergeProfilesCallCount += 1
        lastMergeSourceId = sourceId
        lastMergeTargetId = targetId
        speakers.removeAll { $0.id == sourceId }
    }

    func mergeProfilesByName() {
        mergeByNameCallCount += 1
    }

    func mergeDuplicates() {
        mergeDuplicatesCallCount += 1
    }

    func pruneWeakProfiles() {
        pruneCallCount += 1
    }

    func resetDisputeCount(id: UUID) {
        resetDisputeCallCount += 1
        lastResetDisputeId = id
    }

    func findProfilesByName(_ name: String) -> [SpeakerProfile] {
        findByNameCallCount += 1
        lastFindByNameQuery = name
        return findByNameResult
    }
}

// MARK: - Mock Stats Store

@available(macOS 14.0, *)
final class MockStatsStore: StatsStore {
    var recordings: [(date: String, time: String, durationSeconds: Int, wordCount: Int, speakerCount: Int, processingTimeMs: Int, transcriptPath: String, title: String?)] = []

    var recordTranscriptionCallCount = 0

    func recordTranscription(date: String, time: String, durationSeconds: Int, wordCount: Int, speakerCount: Int, processingTimeMs: Int, transcriptPath: String, title: String?) {
        recordTranscriptionCallCount += 1
        recordings.append((date, time, durationSeconds, wordCount, speakerCount, processingTimeMs, transcriptPath, title))
    }

    func totalRecordingCount() -> Int {
        recordings.count
    }

    func totalDurationSeconds() -> Int {
        recordings.reduce(0) { $0 + $1.durationSeconds }
    }

    func recordingsForDate(_ date: String) -> [RecordingMetadata] {
        []
    }

    func dailyActivity(from startDate: String, to endDate: String) -> [DailyActivity] {
        []
    }
}

// MARK: - Mock Audio Capture Engine

@available(macOS 14.0, *)
final class MockAudioCaptureEngine: ObservableObject, AudioCaptureEngine {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    @Published var recordingDuration: TimeInterval = 0.0
    @Published var systemAudioStatus: SystemAudioStatus = .unknown
    @Published var micAudioFileURL: URL?
    @Published var systemAudioFileURL: URL?

    var onRecordingStart: (() -> Void)?
    var onRecordingComplete: ((URL?, URL?) -> Void)?

    var startCallCount = 0
    var stopCallCount = 0

    func start() {
        startCallCount += 1
        isRecording = true
        onRecordingStart?()
    }

    func stop() {
        stopCallCount += 1
        isRecording = false
        onRecordingComplete?(micAudioFileURL, systemAudioFileURL)
    }

    func createHealthInfo() -> RecordingHealthInfo {
        .perfect
    }
}

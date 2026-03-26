# Service Protocols

7 protocol definitions for dependency injection. Each defines the interface for one service. Conformances exist but are **not yet adopted** in AppServices.swift (still uses concrete types).

## File Index

| File | Conformer | Actor |
|------|-----------|-------|
| `SpeechToTextEngine.swift` | ParakeetService | @MainActor, ObservableObject |
| `DiarizationEngine.swift` | DiarizationService | @MainActor, ObservableObject |
| `SpeakerNamingEngine.swift` | QwenService | @MainActor, ObservableObject |
| `SpeakerStore.swift` | SpeakerDatabase | (no actor — utility queue) |
| `AudioCaptureEngine.swift` | Audio | ObservableObject (NOT @MainActor) |
| `StatsStore.swift` | StatsDatabase | (no actor — serial queue) |
| `TranscriptStorage.swift` | TranscriptSaver | Static methods |

## Protocol Signatures

### SpeechToTextEngine
```swift
@MainActor protocol SpeechToTextEngine: ObservableObject {
    var isReady: Bool { get }
    func initialize() async
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String
    func cleanup()
}
```

### DiarizationEngine
```swift
@MainActor protocol DiarizationEngine: ObservableObject {
    var isReady: Bool { get }
    func initialize() async
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment]
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment]
    func cleanup()
}
```

### SpeakerNamingEngine
```swift
@MainActor protocol SpeakerNamingEngine: ObservableObject {
    static var isEnabled: Bool { get }
    static var isModelCached: Bool { get }
    func loadModel() async
    func unload()
    func inferSpeakerNames(transcript: String) async throws -> QwenInferenceOutput
}
```

### SpeakerStore
```swift
protocol SpeakerStore {
    func matchSpeaker(embedding: [Float], threshold: Double) -> SpeakerMatchResult?
    func addOrUpdateSpeaker(embedding: [Float], existingId: UUID?) -> SpeakerProfile
    func getSpeaker(id: UUID) -> SpeakerProfile?
    func allSpeakers() -> [SpeakerProfile]
    func setDisplayName(id: UUID, name: String, source: String)
    func deleteSpeaker(id: UUID)
    func mergeProfiles(sourceId: UUID, into targetId: UUID)
    func mergeProfilesByName()
    func mergeDuplicates()
    func pruneWeakProfiles()
    func resetDisputeCount(id: UUID)
    func findProfilesByName(_ name: String) -> [SpeakerProfile]
}
```

### AudioCaptureEngine
```swift
protocol AudioCaptureEngine: ObservableObject {
    var isRecording: Bool { get }
    var audioLevel: Float { get }
    var recordingDuration: TimeInterval { get }
    var systemAudioStatus: SystemAudioStatus { get }
    var micAudioFileURL: URL? { get }
    var systemAudioFileURL: URL? { get }
    func start()
    func stop()
    var onRecordingStart: (() -> Void)? { get set }
    var onRecordingComplete: ((URL?, URL?) -> Void)? { get set }
    func createHealthInfo() -> RecordingHealthInfo
}
```

### StatsStore
```swift
protocol StatsStore {
    func recordTranscription(date: String, time: String, durationSeconds: Int,
                             wordCount: Int, speakerCount: Int, processingTimeMs: Int,
                             transcriptPath: String, title: String)
    func totalRecordingCount() -> Int
    func totalDurationSeconds() -> Int
    func recordingsForDate(_ date: String) -> [RecordingMetadata]
    func dailyActivity(from: String, to: String) -> [DailyActivity]
}
```

### TranscriptStorage
```swift
protocol TranscriptStorage {
    static func saveTranscript(_ result: TranscriptionResult,
                               speakerMappings: [String: SpeakerMapping],
                               speakerSources: [String: String],
                               speakerDbIds: [String: UUID],
                               directory: URL?,
                               meetingTitle: String?,
                               healthInfo: RecordingHealthInfo?) -> URL?
    @discardableResult
    static func updateSpeakerNames(transcriptURL: URL, updates: [SpeakerNameUpdate]) -> Bool
    static func retroactivelyUpdateSpeaker(dbId: UUID, newName: String)
    @discardableResult
    static func retroactivelyUpdateTitle(transcriptURL: URL, title: String) -> Bool
    static var defaultSaveDirectory: URL { get }
}
```

## DI Container Status

`Core/AppServices.swift` defines the container but still uses concrete types:
```swift
struct AppServices {
    let speechToText: ParakeetService     // should be: any SpeechToTextEngine
    let diarization: DiarizationService   // should be: any DiarizationEngine
    let speakerNaming: QwenService        // should be: any SpeakerNamingEngine
    let speakerStore: SpeakerDatabase     // should be: any SpeakerStore
}
```
Protocol conformances need to be declared on the concrete types, then AppServices switched to protocol types.

## Relationships
- Protocols used by: Core/AppServices.swift (DI container)
- Conformers in: Services/ root (ParakeetService, DiarizationService, QwenService, SpeakerDatabase) and Core/ (Audio, StatsDatabase, TranscriptSaver)
- Key types referenced: SpeakerSegment, SpeakerProfile, SpeakerMatchResult (Services/SpeakerProfile.swift), AudioSource (FluidAudio framework), RecordingHealthInfo (Core/TranscriptMetadataBuilder.swift)

## Gotchas
- `SpeakerNamingEngine` has static properties (`isEnabled`, `isModelCached`) — unusual for a protocol
- `TranscriptStorage` uses all static methods — conformer (TranscriptSaver) is a utility class, not an instance
- `AudioCaptureEngine` is NOT @MainActor despite most protocols being @MainActor — Audio runs on audio threads
- These protocols are aspirational — the codebase still uses concrete types directly in most places

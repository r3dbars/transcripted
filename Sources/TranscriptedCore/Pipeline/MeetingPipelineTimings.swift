import Foundation

/// Where one meeting transcription spent its time, for speed telemetry.
///
/// The task manager binds one recorder per job with `$current.withValue`,
/// and each stage adds its own wall time through `current`. A task-local
/// reaches every stage of the job (including the app-side speech adapter)
/// without threading a parameter through the pipeline, and a stage that
/// runs outside a bound job records nothing.
///
/// Only durations and counts are kept: no audio, text, names, or paths.
public final class MeetingPipelineTimings: @unchecked Sendable {
    @TaskLocal public static var current: MeetingPipelineTimings?

    public enum Stage: Sendable {
        case modelsReady
        case resample
        case diarize
        case speechToText
    }

    public struct Snapshot: Equatable, Sendable {
        /// Job start to save, as the wall clock saw it (includes sleep).
        public var processingSeconds: Double
        /// Part of `processingSeconds` the Mac spent asleep.
        public var sleepSeconds: Double
        public var modelsReadySeconds: Double
        public var resampleSeconds: Double
        public var diarizeSeconds: Double
        public var speechToTextSeconds: Double
        /// Number of speech-to-text calls (one per speech segment today).
        public var speechToTextCalls: Int
        /// Seconds of audio handed to speech-to-text across those calls.
        public var speechToTextInputSeconds: Double
        /// Longest track of the recording, when the pipeline read it.
        public var recordingSeconds: Double?
        /// Speech model id the app reported, when it did.
        public var speechModel: String?
    }

    private let lock = NSLock()
    private let startedAt: Date
    private let startedUptime: TimeInterval
    private var stageSeconds: [Stage: Double] = [:]
    private var speechToTextCalls = 0
    private var speechToTextInputSeconds: Double = 0
    private var recordingSeconds: Double?
    private var speechModel: String?

    public init(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        startedAt = now
        startedUptime = uptime
    }

    public func add(_ stage: Stage, seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        lock.lock()
        stageSeconds[stage, default: 0] += seconds
        lock.unlock()
    }

    public func addSpeechToTextCall(seconds: Double, inputSeconds: Double, model: String?) {
        add(.speechToText, seconds: seconds)
        lock.lock()
        speechToTextCalls += 1
        if inputSeconds.isFinite, inputSeconds > 0 {
            speechToTextInputSeconds += inputSeconds
        }
        if let model { speechModel = model }
        lock.unlock()
    }

    public func recordRecordingLength(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        lock.lock()
        recordingSeconds = max(recordingSeconds ?? 0, seconds)
        lock.unlock()
    }

    public func snapshot(
        now: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        // `systemUptime` stops while the Mac sleeps and the wall clock does
        // not, so the difference is time asleep.
        let wall = max(0, now.timeIntervalSince(startedAt))
        let awake = max(0, uptime - startedUptime)
        return Snapshot(
            processingSeconds: wall,
            sleepSeconds: max(0, wall - awake),
            modelsReadySeconds: stageSeconds[.modelsReady] ?? 0,
            resampleSeconds: stageSeconds[.resample] ?? 0,
            diarizeSeconds: stageSeconds[.diarize] ?? 0,
            speechToTextSeconds: stageSeconds[.speechToText] ?? 0,
            speechToTextCalls: speechToTextCalls,
            speechToTextInputSeconds: speechToTextInputSeconds,
            recordingSeconds: recordingSeconds,
            speechModel: speechModel
        )
    }

    /// Adds the wall time of `body` to `stage` on the bound recorder, if any.
    @discardableResult
    public static func measure<T>(_ stage: Stage, _ body: () throws -> T) rethrows -> T {
        guard let recorder = current else { return try body() }
        let start = ProcessInfo.processInfo.systemUptime
        defer { recorder.add(stage, seconds: ProcessInfo.processInfo.systemUptime - start) }
        return try body()
    }

    @discardableResult
    public static func measureAsync<T>(_ stage: Stage, _ body: () async throws -> T) async rethrows -> T {
        guard let recorder = current else { return try await body() }
        let start = ProcessInfo.processInfo.systemUptime
        defer { recorder.add(stage, seconds: ProcessInfo.processInfo.systemUptime - start) }
        return try await body()
    }
}

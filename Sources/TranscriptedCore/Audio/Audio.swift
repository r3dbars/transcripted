import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine

/// Lifecycle cues emitted by `Audio` so embedders can react without `Audio`
/// itself depending on AppKit / NSSound.
///
/// `recordingStarted` / `recordingStopped` are cosmetic (UI sounds).
/// `micAttenuatedByForeignVoiceProcessing` is an actionable one-shot signal:
/// the mic stayed attenuated for ~30s despite the software AGC pinned at max
/// gain (issue #500 — a foreign app holds the shared input device in macOS
/// voice/communication mode). Hosts may route it to a consent prompt that
/// offers Apple voice processing for the active recording.
public enum CaptureLifecycleCue: Sendable {
    case recordingStarted
    case recordingStopped
    case micAttenuatedByForeignVoiceProcessing
}

/// Status of system audio capture for UI feedback
/// Used to show warnings when device switching or audio loss occurs
public enum SystemAudioStatus: Equatable {
    case unknown        // Not recording
    case healthy        // Receiving audio data normally
    case reconnecting   // Device change detected, recovering (~200ms)
    case silent         // Prolonged silence (>10s) - might indicate capture issue
    case failed         // Recovery failed - system audio unavailable

    public var isWarning: Bool {
        switch self {
        case .silent, .failed: return true
        default: return false
        }
    }

    public var isRecovering: Bool {
        self == .reconnecting
    }

    public var displayText: String {
        switch self {
        case .unknown: return ""
        case .healthy: return ""
        case .reconnecting: return "Reconnecting..."
        case .silent: return "System audio silent"
        case .failed: return "System audio unavailable \u{2014} enable System Audio Recording for Transcripted in System Settings"
        }
    }
}

struct AudioRecordingFormatSnapshot: Equatable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
}

struct AudioCaptureStaleSessionError: LocalizedError {
    var errorDescription: String? {
        "Recording start was cancelled before audio capture finished"
    }
}

enum AudioRecordingFormatPolicy {
    private static let minimumUsableSampleRate: Double = 8_000
    private static let maximumUsableSampleRate: Double = 384_000

    static func snapshot(_ format: AVAudioFormat) -> AudioRecordingFormatSnapshot? {
        let sampleRate = format.sampleRate
        let channelCount = format.channelCount
        guard isUsableSampleRate(sampleRate), channelCount > 0 else {
            return nil
        }
        return AudioRecordingFormatSnapshot(sampleRate: sampleRate, channelCount: channelCount)
    }

    static func isUsableSampleRate(_ sampleRate: Double) -> Bool {
        sampleRate.isFinite
            && sampleRate >= minimumUsableSampleRate
            && sampleRate <= maximumUsableSampleRate
    }

    static func displaySampleRate(_ sampleRate: Double) -> String {
        isUsableSampleRate(sampleRate) ? "\(Int(sampleRate))" : "invalid"
    }

    static func makeMonoOutputFormat(sampleRate: Double) throws -> AVAudioFormat {
        guard isUsableSampleRate(sampleRate) else {
            throw NSError(domain: "AudioRecordingFormatPolicy", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Refusing to create mic format from invalid sample rate"
            ])
        }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(domain: "AudioRecordingFormatPolicy", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create mono mic format"
            ])
        }

        return monoFormat
    }
}

public enum AudioInputTapTeardownStep: Equatable, Sendable {
    case stopEngine
    case waitForStoppedInputCallbacks
    case removeInputTap
}

/// Single source of truth for the order in which an AVAudioEngine input tap may
/// be torn down. A running graph MUST stop and let in-flight input callbacks
/// drain BEFORE the tap is removed; otherwise CoreAudio can deliver input to a
/// node that has neither a tap nor a sink and trips the fatal assertion
/// `required condition is false: isSink || tap != nullptr`.
///
/// Shared by the meeting/mic capture path (`Audio.tearDownInputTapSafely`) and
/// the dictation path (`ParakeetEngine`) so both honor the same ordering.
public enum AudioInputTapTeardownPolicy {
    public static let inputCallbackDrainDelay: TimeInterval = 0.05

    public static func steps(engineIsRunning: Bool) -> [AudioInputTapTeardownStep] {
        engineIsRunning
            ? [.stopEngine, .waitForStoppedInputCallbacks, .removeInputTap]
            : [.removeInputTap]
    }
}

/// Host-provided sleep/wake notifications for recording gap tracking.
///
/// The default uses macOS workspace notification names without importing
/// AppKit, so `TranscriptedCore` stays a reusable library boundary.
public struct AudioSleepWakeNotifications: Sendable {
    public let center: NotificationCenter
    public let willSleepName: Notification.Name
    public let didWakeName: Notification.Name

    public init(
        center: NotificationCenter = .default,
        willSleepName: Notification.Name,
        didWakeName: Notification.Name
    ) {
        self.center = center
        self.willSleepName = willSleepName
        self.didWakeName = didWakeName
    }

    public static let macOSWorkspace = AudioSleepWakeNotifications(
        willSleepName: Notification.Name("NSWorkspaceWillSleepNotification"),
        didWakeName: Notification.Name("NSWorkspaceDidWakeNotification")
    )
}

/// Main audio recording class that captures microphone and system audio
/// Note: This class does NOT use @MainActor because it manages AVAudioEngine
/// which requires synchronous access from audio tap callbacks on audio threads.
/// UI updates are dispatched to main thread explicitly.
/// The mutable audio-capture state is guarded by dedicated queues, locks, and
/// explicit main-thread dispatch where needed, so Dispatch callbacks can safely
/// hold weak references to this object.
public class Audio: ObservableObject, @unchecked Sendable {
    @Published public var isRecording: Bool = false
    @Published public private(set) var isMonitoring: Bool = false  // Lightweight level metering without file recording
    private var isStarting: Bool = false  // Prevents double-start during async setup
    private var pendingStartIntentId: UUID?
    @Published public var audioLevel: Float = 0.0
    @Published public var recordingDuration: TimeInterval = 0.0
    @Published public var audioLevelHistory: [Float] = Array(repeating: 0.0, count: 15)
    @Published public var systemAudioLevelHistory: [Float] = Array(repeating: 0.0, count: 15)
    @Published public var error: String?
    @Published public var systemAudioStatus: SystemAudioStatus = .unknown

    // Silence detection for "Still Recording?" prompt
    @Published public var silenceDuration: TimeInterval = 0.0  // How long we've been in silence
    @Published public var isSilent: Bool = false  // True when audio below threshold
    let silenceThreshold: Float = 0.02  // Audio level below this = silence
    var lastNonSilentTime: Date?

    // Audio file URLs - returned when recording stops
    @Published public var micAudioFileURL: URL?
    @Published public var systemAudioFileURL: URL?

    /// True once the system-audio tap has actually delivered its first buffer
    /// for the current recording. Meeting-capture readiness
    /// (`AudioCaptureStartState`) must not promote `.waiting` → `.ready` on
    /// "I/O proc started + file URL assigned" alone: a tap can install, get a
    /// file URL, and then silently never stream, losing the entire remote side
    /// of a call. The setter is module-internal; the flag is flipped from the
    /// system buffer callback via `markSystemAudioStreamingIfCurrent` and reset
    /// at each start in `prepareForNewRecordingStart`.
    @Published public internal(set) var systemAudioStreaming: Bool = false

    // Base mic URL set at recording start. If recovery creates additional mic WAV
    // segments, this remains the anchor used to name any merged output passed to
    // the pipeline on stop.
    var originalMicAudioFileURL: URL?
    private var _micSegments: [MicRecordingSegment] = []
    private let micSegmentsLock = NSLock()
    var micSegments: [MicRecordingSegment] {
        get { micSegmentsLock.lock(); defer { micSegmentsLock.unlock() }; return _micSegments }
        set { micSegmentsLock.lock(); defer { micSegmentsLock.unlock() }; _micSegments = newValue }
    }
    func appendMicSegment(_ segment: MicRecordingSegment) {
        micSegmentsLock.lock()
        _micSegments.append(segment)
        let segments = _micSegments
        micSegmentsLock.unlock()
        recordingJournal.recordSegments(segments, session: journalSession)
    }

    // Journal ownership for the in-flight recording session. Issued by the
    // store when the start path calls `begin()`; consumed (read-and-cleared)
    // by `stop()` so only the stop that ends an active session can write the
    // stopping/finalized journal states.
    private var _journalSession: MeetingRecordingJournalSession?
    private let journalSessionLock = NSLock()
    var journalSession: MeetingRecordingJournalSession? {
        get { journalSessionLock.lock(); defer { journalSessionLock.unlock() }; return _journalSession }
        set { journalSessionLock.lock(); defer { journalSessionLock.unlock() }; _journalSession = newValue }
    }
    func takeJournalSession() -> MeetingRecordingJournalSession? {
        journalSessionLock.lock()
        defer { journalSessionLock.unlock() }
        let session = _journalSession
        _journalSession = nil
        return session
    }

    // MARK: - Recording Health Tracking (Phase 1: Sleep/Wake + Gap Logging)

    /// Simple struct to track audio gaps (sleep/wake, device switches)
    struct AudioGap {
        let start: Date
        let duration: TimeInterval
        let reason: String

        var description: String {
            let durationStr = String(format: "%.1f", duration)
            return "\(reason): \(durationStr)s"
        }
    }

    /// Gaps detected during recording (sleep/wake, device switches)
    /// Thread-safe: mutated from main thread (wake handler) + background thread (device recovery)
    private var _recordingGaps: [AudioGap] = []
    private let recordingGapsLock = NSLock()
    var recordingGaps: [AudioGap] {
        get { recordingGapsLock.lock(); defer { recordingGapsLock.unlock() }; return _recordingGaps }
        set { recordingGapsLock.lock(); defer { recordingGapsLock.unlock() }; _recordingGaps = newValue }
    }
    func appendRecordingGap(_ gap: AudioGap) {
        recordingGapsLock.lock(); defer { recordingGapsLock.unlock() }
        _recordingGaps.append(gap)
    }

    /// Count of device switches during this recording
    /// Thread-safe: reset on main thread, incremented on background recovery thread
    private var _deviceSwitchCount: Int = 0
    private let deviceSwitchCountLock = NSLock()
    var deviceSwitchCount: Int {
        get { deviceSwitchCountLock.lock(); defer { deviceSwitchCountLock.unlock() }; return _deviceSwitchCount }
        set { deviceSwitchCountLock.lock(); defer { deviceSwitchCountLock.unlock() }; _deviceSwitchCount = newValue }
    }

    /// Timestamp when system started sleeping (for gap calculation)
    var sleepTimestamp: Date?

    /// Create a snapshot of recording health info for transcript metadata
    /// using the live `systemAudioStatus`. Used by callers that snapshot
    /// BEFORE calling `stop()` (and by the `AudioCaptureEngine` protocol
    /// conformance, which doesn't model the override path).
    /// `systemAudioCapture` stays type-erased here; the `RecordingHealthInfo`
    /// factory downcasts under `#available(macOS 14.2, *)` internally.
    public func createHealthInfo() -> RecordingHealthInfo {
        return RecordingHealthInfo.from(audio: self, systemCapture: systemAudioCapture)
    }

    /// Create a snapshot of recording health info using a pre-captured
    /// `systemAudioStatus`. Use this when snapshotting AFTER `stop()` —
    /// the live status has been reset to `.unknown`, but a real `.failed`
    /// outcome captured before stop must still drive `captureQuality`.
    /// Lock-protected fields (gaps, deviceSwitchCount, recoveryAttemptCount)
    /// are not reset by stop, so they read correctly post-stop without
    /// contending with the audio thread.
    public func createHealthInfo(
        overrideSystemAudioStatus: SystemAudioStatus?
    ) -> RecordingHealthInfo {
        return RecordingHealthInfo.from(
            audio: self,
            systemCapture: systemAudioCapture,
            overrideSystemAudioStatus: overrideSystemAudioStatus
        )
    }

    var engine: AVAudioEngine?
    var inputNode: AVAudioInputNode?
    private let audioGraphLock = NSRecursiveLock()
    var startTime: Date?
    var timer: Timer?

    // True once setVoiceProcessingEnabled(true) has succeeded on the current
    // inputNode. Reset whenever engine.reset() runs (device recovery) so we
    // re-arm VPIO before reinstalling the tap. Issue #500: Safari/Firefox
    // WebRTC activates AUVoiceProcessingIO on the shared input device which
    // hands every other reader an attenuated stream; running our own VPIO
    // gives us our own AGC'd copy.
    var voiceProcessingEnabled: Bool = false

    /// Whether to arm Apple's AUVoiceProcessingIO (VPIO) on the meeting mic
    /// engine. Default off because VPIO causes macOS to duck audio output
    /// from other apps (Zoom plays Katie's voice quieter while we're
    /// recording — observed in production after PR #523). Set this BEFORE
    /// calling `start()`; toggling mid-session has no effect until the next
    /// recording begins. The app reads `MicrophoneProcessingPreferences`
    /// and assigns this property; `TranscriptedCore` itself never reaches
    /// into UserDefaults.
    public var enableVoiceProcessing: Bool = false

    /// Whether Transcripted should run its software gain control on the copied
    /// mic buffer when Apple voice processing is not active. Default on for the
    /// existing quiet-WebRTC recovery path; users with tuned hardware mics can
    /// turn it off so saved mic audio stays raw.
    public var enableSoftwareAGC: Bool = true

    /// Real-time gain control for the mic tap callback. Used when VPIO is
    /// disabled (the default) to recover attenuated streams (e.g. Safari/
    /// Firefox WebRTC contention from issue #500) without engaging Apple's
    /// system-wide voice-comms ducking. Lazily created at start, reset on
    /// device recovery, deinit'd at stop.
    var realtimeAGC: RealtimeAGC?

    /// Live issue #500 attenuation detector. Main-thread-only: replaced on
    /// the start path in `prepareForNewRecordingStart`, consumed only by the
    /// 0.2s recording timer (both effectively main); no lock.
    var quietMicAttenuationDetector = QuietMicAttenuationDetector()

    // Device change watchdog - thread-safe access via lock
    // Uses CACurrentMediaTime() (monotonic clock) to avoid false triggers after sleep/wake.
    // Matches SystemAudioCapture.swift which also uses CACurrentMediaTime().
    private var _lastBufferTime: CFTimeInterval = CACurrentMediaTime()
    private let lastBufferTimeLock = NSLock()
    var lastBufferTime: CFTimeInterval {
        get {
            lastBufferTimeLock.lock()
            defer { lastBufferTimeLock.unlock() }
            return _lastBufferTime
        }
        set {
            lastBufferTimeLock.lock()
            defer { lastBufferTimeLock.unlock() }
            _lastBufferTime = newValue
        }
    }
    var watchdogTimer: Timer?

    // Mic recovery guard (prevents concurrent recovery attempts)
    // Thread-safe: accessed from watchdog (main) and recovery (background) threads
    private var _isMicRecovering: Bool = false
    private let micRecoveryLock = NSLock()
    var isMicRecovering: Bool {
        get {
            micRecoveryLock.lock()
            defer { micRecoveryLock.unlock() }
            return _isMicRecovering
        }
        set {
            micRecoveryLock.lock()
            defer { micRecoveryLock.unlock() }
            _isMicRecovering = newValue
        }
    }
    var lastRecoveryTime: Date?
    private var _recoveryAttemptCount: Int = 0
    private let recoveryAttemptCountLock = NSLock()
    var recoveryAttemptCount: Int {
        get {
            recoveryAttemptCountLock.lock()
            defer { recoveryAttemptCountLock.unlock() }
            return _recoveryAttemptCount
        }
        set {
            recoveryAttemptCountLock.lock()
            defer { recoveryAttemptCountLock.unlock() }
            _recoveryAttemptCount = newValue
        }
    }
    // Recording session generation - increments on each start/stop so delayed
    // recovery work from an old session cannot restart a newer one.
    private var _recordingSessionGeneration: UInt64 = 0
    private let recordingSessionGenerationLock = NSLock()
    var recordingSessionGeneration: UInt64 {
        get {
            recordingSessionGenerationLock.lock()
            defer { recordingSessionGenerationLock.unlock() }
            return _recordingSessionGeneration
        }
        set {
            recordingSessionGenerationLock.lock()
            defer { recordingSessionGenerationLock.unlock() }
            _recordingSessionGeneration = newValue
        }
    }
    let maxRecoveryAttempts = 5
    let recoveryCooldown: TimeInterval = 5.0  // Min seconds between recovery attempts

    func withAudioGraphLock<T>(_ body: () throws -> T) rethrows -> T {
        audioGraphLock.lock()
        defer { audioGraphLock.unlock() }
        return try body()
    }

    func tearDownInputTapSafely(
        engine: AVAudioEngine,
        inputNode: AVAudioInputNode,
        operation: String
    ) {
        let steps = AudioInputTapTeardownPolicy.steps(engineIsRunning: engine.isRunning)
        for step in steps {
            switch step {
            case .stopEngine:
                AppLogger.audioMic.info("Stopping mic engine before removing input tap", [
                    "operation": operation
                ])
                engine.stop()
            case .waitForStoppedInputCallbacks:
                Thread.sleep(forTimeInterval: AudioInputTapTeardownPolicy.inputCallbackDrainDelay)
            case .removeInputTap:
                inputNode.removeTap(onBus: 0)
            }
        }
    }

    // Write error tracking — stop writing after repeated failures
    // Thread-safe: accessed from audio file queues (background) and reset from start() (main thread)
    private var _consecutiveMicWriteErrors: Int = 0
    private var _consecutiveSystemWriteErrors: Int = 0
    private let writeErrorLock = NSLock()
    var consecutiveMicWriteErrors: Int {
        get { writeErrorLock.lock(); defer { writeErrorLock.unlock() }; return _consecutiveMicWriteErrors }
        set { writeErrorLock.lock(); defer { writeErrorLock.unlock() }; _consecutiveMicWriteErrors = newValue }
    }
    var consecutiveSystemWriteErrors: Int {
        get { writeErrorLock.lock(); defer { writeErrorLock.unlock() }; return _consecutiveSystemWriteErrors }
        set { writeErrorLock.lock(); defer { writeErrorLock.unlock() }; _consecutiveSystemWriteErrors = newValue }
    }
    let maxConsecutiveWriteErrors = 10

    // Persistent flag: system audio capture failed, recording mic only
    @Published var systemAudioFailed: Bool = false

    // System audio capture
    var systemAudioCapture: (any SystemAudioCaptureEngine & Sendable)?

    // Audio file recording
    var systemAudioFile: AVAudioFile?
    var micAudioFile: AVAudioFile?
    let systemAudioFileQueue = DispatchQueue(label: "SystemAudioFileWrite", qos: .utility)
    let micAudioFileQueue = DispatchQueue(label: "MicAudioFileWrite", qos: .utility)

    // Audio format conversion (multi-channel to mono)
    // Thread-safe: written during init + device recovery, read during mic buffer handling
    private var _monoOutputFormat: AVAudioFormat?
    private var _inputChannelCount: AVAudioChannelCount = 1
    private let formatLock = NSLock()
    var monoOutputFormat: AVAudioFormat? {
        get { formatLock.lock(); defer { formatLock.unlock() }; return _monoOutputFormat }
        set { formatLock.lock(); defer { formatLock.unlock() }; _monoOutputFormat = newValue }
    }
    var inputChannelCount: AVAudioChannelCount {
        get { formatLock.lock(); defer { formatLock.unlock() }; return _inputChannelCount }
        set { formatLock.lock(); defer { formatLock.unlock() }; _inputChannelCount = newValue }
    }

    // Throttle system audio visualizer updates (skip every other callback)
    // Protected by systemLevelLock — accessed from I/O callback thread
    var systemLevelUpdateCounter: Int = 0
    let systemLevelLock = NSLock()

    // Debug: Track system audio buffer count
    // Protected by systemBufferCountLock — accessed from I/O callback dispatch and main thread
    private var _systemBufferCount: Int = 0
    private let systemBufferCountLock = NSLock()
    var systemBufferCount: Int {
        get {
            systemBufferCountLock.lock()
            defer { systemBufferCountLock.unlock() }
            return _systemBufferCount
        }
        set {
            systemBufferCountLock.lock()
            defer { systemBufferCountLock.unlock() }
            _systemBufferCount = newValue
        }
    }

    // Per-recording signal diagnostics. These are amplitude-only facts used
    // for issue #500 QA; they never include transcript text or raw audio.
    private var _micRawPeak: Float = 0
    private var _micProcessedPeak: Float = 0
    private var _systemAudioPeak: Float = 0
    // Interval-scoped mic facts consumed by the 0.2s recording timer for the
    // live issue #500 attenuation detector. Zeroed every drain so one loud
    // cough cannot mask later attenuation the way the lifetime maxima do.
    // `_intervalMinAppliedGain` is nil when no AGC-processed buffer arrived
    // this interval; updated via min so one unpinned buffer disqualifies
    // the tick.
    private var _intervalMicRawPeak: Float = 0
    private var _intervalMicProcessedPeak: Float = 0
    private var _intervalMinAppliedGain: Float?
    private var _intervalAGCMaxGain: Float?
    private var _intervalSawMicBuffer: Bool = false
    private let signalDiagnosticsLock = NSLock()

    struct MicSignalIntervalDiagnostics {
        let rawPeak: Float
        let processedPeak: Float
        let minAppliedGain: Float?
        let agcMaxGain: Float?
        let sawBuffer: Bool
    }

    var signalDiagnosticsSnapshot: AudioSignalDiagnosticsSnapshot {
        signalDiagnosticsLock.lock()
        defer { signalDiagnosticsLock.unlock() }
        return AudioSignalDiagnosticsSnapshot(
            micRawPeak: _micRawPeak,
            micProcessedPeak: _micProcessedPeak,
            systemAudioPeak: _systemAudioPeak
        )
    }

    func resetSignalDiagnostics() {
        signalDiagnosticsLock.lock()
        defer { signalDiagnosticsLock.unlock() }
        _micRawPeak = 0
        _micProcessedPeak = 0
        _systemAudioPeak = 0
        _intervalMicRawPeak = 0
        _intervalMicProcessedPeak = 0
        _intervalMinAppliedGain = nil
        _intervalAGCMaxGain = nil
        _intervalSawMicBuffer = false
    }

    func recordMicSignalPeaks(raw: Float, processed: Float, appliedGain: Float?, agcMaxGain: Float?) {
        signalDiagnosticsLock.lock()
        defer { signalDiagnosticsLock.unlock() }
        _micRawPeak = max(_micRawPeak, raw)
        _micProcessedPeak = max(_micProcessedPeak, processed)
        _intervalMicRawPeak = max(_intervalMicRawPeak, raw)
        _intervalMicProcessedPeak = max(_intervalMicProcessedPeak, processed)
        if let appliedGain {
            _intervalMinAppliedGain = min(_intervalMinAppliedGain ?? .infinity, appliedGain)
            _intervalAGCMaxGain = agcMaxGain
        }
        _intervalSawMicBuffer = true
    }

    /// Read-and-zero the interval-scoped mic facts. Called only from the
    /// 0.2s recording timer so each tick sees exactly one interval.
    func drainMicSignalIntervalDiagnostics() -> MicSignalIntervalDiagnostics {
        signalDiagnosticsLock.lock()
        defer { signalDiagnosticsLock.unlock() }
        let interval = MicSignalIntervalDiagnostics(
            rawPeak: _intervalMicRawPeak,
            processedPeak: _intervalMicProcessedPeak,
            minAppliedGain: _intervalMinAppliedGain,
            agcMaxGain: _intervalAGCMaxGain,
            sawBuffer: _intervalSawMicBuffer
        )
        _intervalMicRawPeak = 0
        _intervalMicProcessedPeak = 0
        _intervalMinAppliedGain = nil
        _intervalAGCMaxGain = nil
        _intervalSawMicBuffer = false
        return interval
    }

    func recordSystemSignalPeak(_ peak: Float) {
        signalDiagnosticsLock.lock()
        defer { signalDiagnosticsLock.unlock() }
        _systemAudioPeak = max(_systemAudioPeak, peak)
    }

    // Default route volume at recording start. Used only for diagnostics so
    // we can prove Transcripted observed volume scalars rather than changed
    // them.
    private var _recordingStartRouteVolumeSnapshot: AudioRouteVolumeSnapshot?
    private let routeVolumeDiagnosticsLock = NSLock()

    var recordingStartRouteVolumeSnapshot: AudioRouteVolumeSnapshot? {
        get {
            routeVolumeDiagnosticsLock.lock()
            defer { routeVolumeDiagnosticsLock.unlock() }
            return _recordingStartRouteVolumeSnapshot
        }
        set {
            routeVolumeDiagnosticsLock.lock()
            defer { routeVolumeDiagnosticsLock.unlock() }
            _recordingStartRouteVolumeSnapshot = newValue
        }
    }

    // Input volume on the device meetings actually capture from after input
    // selection has run. This can differ from the default input on Bluetooth
    // fallback routes.
    private var _recordingStartCapturedInputVolume = "unavailable"
    private var _recordingStartCapturedInputDeviceID: AudioDeviceID?

    var recordingStartCapturedInputDeviceID: AudioDeviceID? {
        routeVolumeDiagnosticsLock.lock()
        defer { routeVolumeDiagnosticsLock.unlock() }
        return _recordingStartCapturedInputDeviceID
    }

    func recordRecordingStartCapturedInput(deviceID: AudioDeviceID?) {
        let volume = AudioRouteVolumeSnapshot.inputVolumeString(for: deviceID)
        let validDeviceID = deviceID?.isValid == true ? deviceID : nil

        routeVolumeDiagnosticsLock.lock()
        defer { routeVolumeDiagnosticsLock.unlock() }
        _recordingStartCapturedInputDeviceID = validDeviceID
        _recordingStartCapturedInputVolume = volume
    }

    func resetRecordingStartCapturedInput() {
        routeVolumeDiagnosticsLock.lock()
        defer { routeVolumeDiagnosticsLock.unlock() }
        _recordingStartCapturedInputDeviceID = nil
        _recordingStartCapturedInputVolume = "unavailable"
    }

    func recordingStartCapturedInputVolume(matching deviceID: AudioDeviceID?) -> String {
        guard let deviceID, deviceID.isValid else { return "unavailable" }

        routeVolumeDiagnosticsLock.lock()
        defer { routeVolumeDiagnosticsLock.unlock() }
        guard _recordingStartCapturedInputDeviceID == deviceID else { return "unavailable" }
        return _recordingStartCapturedInputVolume
    }

    // System audio status observation
    private var systemAudioCancellable: AnyCancellable?
    // Protected by systemSilenceLock — written from callback thread, reset on main thread
    private var _systemAudioSilenceStart: Date?
    private let systemSilenceLock = NSLock()
    var systemAudioSilenceStart: Date? {
        get {
            systemSilenceLock.lock()
            defer { systemSilenceLock.unlock() }
            return _systemAudioSilenceStart
        }
        set {
            systemSilenceLock.lock()
            defer { systemSilenceLock.unlock() }
            _systemAudioSilenceStart = newValue
        }
    }
    let systemAudioSilenceThreshold: TimeInterval = 10  // 10s of silence = warning

    // Sleep/wake notification observers (stored for cleanup in deinit)
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    // Disk space check counter — checked every 150 timer ticks (~30s at 0.2s interval)
    var diskCheckCounter: Int = 0

    // Callback for when recording completes
    public var onRecordingComplete: ((URL?, URL?) -> Void)?

    // Callback for when recording starts (used for pre-loading models)
    public var onRecordingStart: (() -> Void)?

    // Cosmetic capture lifecycle cues. Embedders decide how (or whether) to
    // surface these — typically a UI sound. Fires from whichever queue the
    // underlying lifecycle event runs on; the host should hop to the main
    // actor before touching UI.
    public var onCaptureLifecycleCue: ((CaptureLifecycleCue) -> Void)?

    // MARK: - Live PCM buffer hooks (host app live-preview integration)
    //
    // These callbacks let an embedder tap the PCM buffers as they arrive
    // from CoreAudio, in parallel with the WAV file writes. Used by the app to
    // drive live dual-channel transcription preview via FluidAudio's
    // StreamingEouAsrManager without a second audio engine.
    //
    // Threading: fired on the audio thread (same thread as the tap callback).
    // Consumers MUST NOT do I/O, locks, or allocations on this thread — copy
    // the buffer and dispatch to a worker queue. Matching the convention of
    // `onRecordingComplete`, optional reads are unsynchronized: set the hook
    // once before `start()` and do not reassign during recording.
    //
    // Mic buffers are the same processed copy that is written to the saved mic
    // WAV: software AGC when VPIO is off, or Apple's VPIO output when VPIO is
    // on. System buffers are not processed by Transcripted; they arrive in the
    // aggregate-device format (typically stereo at 48 kHz). Callers are
    // responsible for any downmix/resample they need.
    //
    // Copy semantics:
    //   onMicPCMBuffer  — owned processed mic copy; caller should still copy before async dispatch.
    //   onSystemPCMBuffer — owned for async use; SCK buffers already own memory, legacy tap buffers are copied.
    public var onMicPCMBuffer: ((AVAudioPCMBuffer) -> Void)?
    public var onSystemPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Filesystem layout used for writing raw mic/system WAV captures.
    /// Embedders can redirect captures by passing a custom `CoreStoragePaths` at init.
    let paths: CoreStoragePaths
    private let sleepWakeNotifications: AudioSleepWakeNotifications

    /// Durable record of the in-flight recording for crash recovery. Lives
    /// next to the scratch audio; cleared once the meeting reaches a durable
    /// state (transcript saved or failed-queue entry persisted).
    let recordingJournal: MeetingRecordingJournalStore

    public init(
        paths: CoreStoragePaths = .default,
        sleepWakeNotifications: AudioSleepWakeNotifications = .macOSWorkspace
    ) {
        self.paths = paths
        self.sleepWakeNotifications = sleepWakeNotifications
        self.recordingJournal = MeetingRecordingJournalStore(directory: paths.audioCaptures)
    }

    init(
        paths: CoreStoragePaths = .default,
        systemAudioCaptureForTesting systemAudioCapture: (any SystemAudioCaptureEngine & Sendable)?,
        sleepWakeNotifications: AudioSleepWakeNotifications = .macOSWorkspace
    ) {
        self.paths = paths
        self.sleepWakeNotifications = sleepWakeNotifications
        self.recordingJournal = MeetingRecordingJournalStore(directory: paths.audioCaptures)
        self.systemAudioCapture = systemAudioCapture
        if let systemAudioCapture {
            wireSystemAudioStatusPublisher(from: systemAudioCapture)
        }
    }

    func ensureCaptureInfrastructureConfigured() {
        guard systemAudioCapture == nil else { return }

        // Initialize system audio capture using the macOS 26+ audio-only
        // ScreenCaptureKit path. This keeps meeting audio on the narrower
        // "System Audio Recording" permission tier and avoids restart-required
        // Screen Recording flows.
        let capture = SCKAudioCapture()
        systemAudioCapture = capture
        wireSystemAudioStatusPublisher(from: capture)
        installWorkspaceSleepWakeObservers()
    }

    private func wireSystemAudioStatusPublisher(from capture: any SystemAudioCaptureEngine) {
        systemAudioCancellable = capture.errorMessagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorMessage in
                self?.updateSystemAudioStatus(fromError: errorMessage)
            }
    }

    func installWorkspaceSleepWakeObservers() {
        // MARK: - Sleep/Wake Observers (Phase 1: Invisible Reliability)
        // Handle macOS sleep/wake to prevent AVAudioEngine crashes and log gaps

        sleepObserver = sleepWakeNotifications.center.addObserver(
            forName: sleepWakeNotifications.willSleepName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            AppLogger.audio.info("System sleeping during recording - preparing for gap")
            self.sleepTimestamp = Date()
        }

        wakeObserver = sleepWakeNotifications.center.addObserver(
            forName: sleepWakeNotifications.didWakeName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            AppLogger.audio.info("System waking - waiting for HAL stabilization")

            // Wait 500ms for audio subsystem to stabilize before continuing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, self.isRecording else { return }

                // Record the gap
                if let sleepStart = self.sleepTimestamp {
                    let gap = AudioGap(
                        start: sleepStart,
                        duration: Date().timeIntervalSince(sleepStart),
                        reason: "Sleep/wake"
                    )
                    self.appendRecordingGap(gap)
                    AppLogger.audio.info("Recorded sleep/wake gap", ["gap": gap.description])
                }
                self.sleepTimestamp = nil

                // Proactively trigger mic recovery instead of waiting for the 3-5s watchdog delay
                let sessionGeneration = self.recordingSessionGeneration
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self, self.isRecording else { return }
                    self.recoverFromDeviceChange(sessionGeneration: sessionGeneration)
                }
            }
        }
    }

    @discardableResult
    func ensureEngineInitialized() throws -> (AVAudioEngine, AVAudioInputNode) {
        // Delay AVAudioEngine/input-node access until monitoring or recording
        // actually begins. Launch-time warmup can construct Audio long before
        // the user has explicitly asked to record anything.
        if engine == nil {
            engine = AVAudioEngine()
        }

        if inputNode == nil, let engine {
            inputNode = engine.inputNode
            AppLogger.audioMic.info("Using system default microphone")
        }

        guard let engine, let inputNode else {
            throw NSError(
                domain: "Audio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Engine not initialized"]
            )
        }

        return (engine, inputNode)
    }

    /// Format the mic tap will actually deliver. With VPIO enabled the tap
    /// receives the VPIO output (mono Float32 at the unit's preferred rate),
    /// not the raw hardware format. Without VPIO we keep using the hardware
    /// format read on bus 1 so Bluetooth devices keep working.
    func recordingFormat(for inputNode: AVAudioInputNode) -> AVAudioFormat {
        if voiceProcessingEnabled {
            return inputNode.outputFormat(forBus: 0)
        }
        return inputNode.inputFormat(forBus: 1)
    }

    func refreshRealtimeAGCForCurrentProcessingMode(resetExisting: Bool = false) {
        if voiceProcessingEnabled || !enableSoftwareAGC {
            realtimeAGC = nil
        } else if let existing = realtimeAGC {
            if resetExisting {
                existing.reset()
            }
        } else {
            realtimeAGC = RealtimeAGC()
        }
    }

    /// Enable AUVoiceProcessingIO on the meeting input node so Transcripted
    /// gets its own AGC'd copy of the mic stream rather than reading the raw
    /// shared device. Issue #500: when Safari/Firefox WebRTC has VPIO active
    /// on the same physical device, plain AVAudioEngine taps see attenuated
    /// audio and meeting recordings come out very quiet.
    ///
    /// VPIO has a documented side effect: macOS treats any VPIO holder as a
    /// voice-comms app and ducks output from other apps (Zoom playback,
    /// Spotify, etc.). For most users that's worse than the original quiet-
    /// recording bug, so VPIO is now opt-in via `enableVoiceProcessing`. The
    /// software AGC in `RealtimeAGC` (installed in the tap callback when
    /// VPIO is off) handles issue #500 for everyone else without engaging
    /// the system ducking.
    ///
    /// Idempotent and safe to call repeatedly. Skips when the engine is
    /// already running (toggling VPIO requires a stopped engine). Falls back
    /// silently when the device cannot host VPIO (rare, e.g. unusual
    /// aggregate devices) so a VPIO failure never blocks recording.
    func armVoiceProcessing(on inputNode: AVAudioInputNode) {
        guard enableVoiceProcessing else {
            // Opt-in toggle is off. Be explicit here instead of trusting our
            // cached flag, because a prior route change can leave VPIO armed
            // until the input node is told to release it.
            disarmVoiceProcessing(on: inputNode, reason: "preference_off")
            return
        }

        if voiceProcessingEnabled, inputNode.isVoiceProcessingEnabled {
            return
        }

        if let engine, engine.isRunning {
            // VPIO can only be toggled while the engine is stopped. Defer until
            // the next start cycle re-enters this path.
            return
        }

        do {
            try inputNode.setVoiceProcessingEnabled(true)
            inputNode.isVoiceProcessingAGCEnabled = true
            if #available(macOS 14.0, *) {
                inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
            }
            voiceProcessingEnabled = true
            AppLogger.audioMic.info("Voice processing enabled on meeting mic", [
                "agc": "\(inputNode.isVoiceProcessingAGCEnabled)",
                "ducking": "min",
                "reason": "issue_500_safari_firefox_vpio_contention"
            ])
        } catch {
            voiceProcessingEnabled = false
            AppLogger.audioMic.warning("Voice processing unavailable, continuing without it", [
                "error": error.localizedDescription
            ])
        }
    }

    /// Disable VPIO once active meeting capture ends. Leaving it armed after
    /// capture can keep the shared input device in a processed mode, which can
    /// make other mic apps sound quieter.
    func disarmVoiceProcessing(on inputNode: AVAudioInputNode, reason: String = "recording_stopped") {
        if let engine, engine.isRunning { return }
        let wasMarkedEnabled = voiceProcessingEnabled
        let wasActuallyEnabled = inputNode.isVoiceProcessingEnabled
        guard wasMarkedEnabled || wasActuallyEnabled else {
            voiceProcessingEnabled = false
            return
        }

        do {
            try inputNode.setVoiceProcessingEnabled(false)
            AppLogger.audioMic.info("Voice processing disabled on meeting mic", [
                "reason": reason,
                "was_marked_enabled": "\(wasMarkedEnabled)",
                "was_actually_enabled": "\(wasActuallyEnabled)"
            ])
        } catch {
            AppLogger.audioMic.warning("Voice processing disable failed", [
                "error": error.localizedDescription
            ])
        }
        voiceProcessingEnabled = false
    }

    func prepareForNewRecordingStart() {
        error = nil
        isMicRecovering = false
        systemBufferCount = 0  // Reset debug counter (lock-protected)
        systemAudioStreaming = false  // Re-gate readiness on a fresh first buffer
        resetSignalDiagnostics()
        // Fresh instance = clean one-shot latch per recording.
        quietMicAttenuationDetector = QuietMicAttenuationDetector()
        recordingStartRouteVolumeSnapshot = AudioRouteVolumeSnapshot.captureDefaultRoute()
        resetRecordingStartCapturedInput()
        resetSilenceTracking()  // Start fresh silence tracking
        systemAudioStatus = .healthy  // Assume healthy until we hear otherwise
        systemAudioSilenceStart = nil  // Reset system audio silence tracking
        recordingSessionGeneration &+= 1

        // Reset capture artifacts so a previous session cannot make a new start
        // look ready before the fresh mic/system files exist.
        originalMicAudioFileURL = nil
        micAudioFileURL = nil
        systemAudioFileURL = nil

        // Reset health tracking for new recording session
        recordingGaps = []
        deviceSwitchCount = 0
        recoveryAttemptCount = 0
        sleepTimestamp = nil
        lastRecoveryTime = nil
        consecutiveMicWriteErrors = 0
        consecutiveSystemWriteErrors = 0
        systemAudioFailed = false
        micSegments = []
        // Any leftover journal ownership belongs to a session that never
        // stopped cleanly; the new session gets a fresh token at begin().
        journalSession = nil
    }

    private func beginStartIntent() -> UUID {
        // Gate duplicate start requests while the permission prompt is open or
        // the async recorder setup is still being scheduled.
        isStarting = true
        let id = UUID()
        pendingStartIntentId = id
        return id
    }

    private func isCurrentStartIntent(_ id: UUID) -> Bool {
        pendingStartIntentId == id && isStarting && !isRecording
    }

    private func clearStartIntent(_ id: UUID) {
        if pendingStartIntentId == id {
            pendingStartIntentId = nil
        }
    }

    // MARK: - Start Recording

    public func start() {
        guard !isRecording, !isStarting else {
            AppLogger.audio.warning("Already recording or starting, ignoring duplicate start request")
            return
        }

        // Stop monitoring if active — full recording takes over the engine and taps
        if isMonitoring {
            stopMonitoring()
        }

        // Pre-flight validation checks
        let validationResult = RecordingValidator.validateRecordingConditions(paths: paths)
        guard validationResult.isValid else {
            AppLogger.audio.error("Pre-flight check failed", ["error": validationResult.errorMessage ?? "Unknown error"])
            error = validationResult.errorMessage
            return
        }

        let startIntentId = beginStartIntent()

        // Check microphone permission and request if not determined
        // This allows users who skipped permission during onboarding to grant it at record time
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    guard self.isCurrentStartIntent(startIntentId) else {
                        AppLogger.audio.info("Ignoring stale microphone permission response after start was cancelled")
                        return
                    }

                    if granted {
                        // Permission granted, proceed with start
                        self.startAudioCaptureAsync(startIntentId: startIntentId)
                    } else {
                        // Permission denied — already on main via the outer dispatch
                        self.error = "Microphone permission required. Go to System Settings \u{2192} Privacy & Security \u{2192} Microphone and enable Transcripted, then try again."
                        self.isStarting = false
                        self.clearStartIntent(startIntentId)
                    }
                }
            }
            return
        } else if microphoneStatus == .denied {
            // Permission explicitly denied
            DispatchQueue.main.async {
                guard self.isCurrentStartIntent(startIntentId) else { return }
                self.error = "Microphone access denied. Go to System Settings \u{2192} Privacy & Security \u{2192} Microphone and enable Transcripted."
                self.isStarting = false
                self.clearStartIntent(startIntentId)
            }
            return
        }
        startAudioCaptureAsync(startIntentId: startIntentId)
    }

    /// Helper method to start audio capture asynchronously
    /// Used when permission is already granted or after permission request completes
    private func startAudioCaptureAsync(startIntentId: UUID) {
        guard isCurrentStartIntent(startIntentId) else {
            AppLogger.audio.info("Ignoring stale audio capture start request after start was cancelled")
            return
        }

        isStarting = true
        clearStartIntent(startIntentId)
        prepareForNewRecordingStart()
        let startGeneration = recordingSessionGeneration

        AppLogger.audio.info("Starting audio capture")

        onRecordingStart?()

        Task {
            do {
                try await startAudioCapture(sessionGeneration: startGeneration)
                await MainActor.run {
                    self.finishSuccessfulStartIfCurrent(startGeneration)
                }
            } catch {
                await MainActor.run {
                    guard self.recordingSessionGeneration == startGeneration else {
                        AppLogger.audio.info("Skipping stale start failure after session boundary", [
                            "startGeneration": "\(startGeneration)",
                            "currentGeneration": "\(self.recordingSessionGeneration)"
                        ])
                        return
                    }

                    self.error = "Recording failed to start: \(error.localizedDescription). Try quitting and reopening Transcripted."
                    self.isRecording = false
                    self.isStarting = false
                    self.stop()
                }
            }
        }
    }

    @MainActor
    private func finishSuccessfulStartIfCurrent(_ startGeneration: UInt64) {
        guard recordingSessionGeneration == startGeneration, isStarting else {
            AppLogger.audio.warning("Audio capture start finished after session was cancelled; tearing down stale capture", [
                "startGeneration": "\(startGeneration)",
                "currentGeneration": "\(recordingSessionGeneration)"
            ])
            if recordingSessionGeneration == startGeneration {
                isRecording = false
                isStarting = false
            }
            return
        }

        isRecording = true
        isStarting = false
        restoreSystemAudioHealthyStatusAfterSuccessfulStart()
    }

    func restoreSystemAudioHealthyStatusAfterSuccessfulStart() {
        guard systemAudioFileURL != nil,
              !systemAudioFailed,
              systemAudioStatus == .unknown else {
            return
        }

        systemAudioStatus = .healthy
    }

    func assignSystemAudioFileURLIfCurrent(_ fileURL: URL, sessionGeneration: UInt64) {
        guard recordingSessionGeneration == sessionGeneration else { return }

        systemAudioFileURL = fileURL
        recordingJournal.recordSystemAudio(fileURL, session: journalSession)
        restoreSystemAudioHealthyStatusAfterSuccessfulStart()
    }

    /// Records that the system-audio tap has started streaming for this
    /// recording. Called from the system buffer callback on its first buffer
    /// (on a CoreAudio dispatch thread), so it hops to main to publish
    /// `systemAudioStreaming`. Generation-guarded so a late buffer from a
    /// finished session cannot re-arm readiness. This is the signal that
    /// promotes meeting-capture readiness (`AudioCaptureStartState`) from
    /// `.waiting` to `.ready`: a tap that installs but never streams never sets
    /// it, so the start deadline fails it instead of reporting "recording".
    func markSystemAudioStreamingIfCurrent(sessionGeneration: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recordingSessionGeneration == sessionGeneration else { return }
            self.systemAudioStreaming = true
        }
    }

    // MARK: - Stop Recording

    public func stop() {
        // Bump generation synchronously on the calling thread so any
        // concurrent recovery work that checks the generation immediately
        // sees the new session boundary.
        pendingStartIntentId = nil
        recordingSessionGeneration &+= 1
        let stopGeneration = recordingSessionGeneration

        // Snapshot every reference the teardown will need so the
        // background queue closure isn't reading mutable instance state
        // while UI updates happen in parallel.
        let engineRef = self.engine
        let inputNodeRef = self.inputNode
        let systemCaptureRef = self.systemAudioCapture
        let micAudioFileRef = micAudioFileQueue.sync { self.micAudioFile }
        let systemAudioFileRef = systemAudioFileQueue.sync { self.systemAudioFile }
        // Use the original mic URL (set at recording start), not the potentially-overwritten
        // recovery URL. Device recovery creates a new WAV segment but the original file
        // contains the bulk of the recording.
        let primaryMicURL = originalMicAudioFileURL ?? micAudioFileURL
        let micSegmentsSnapshot = self.micSegments
        let finalSystemURL = systemAudioFileURL
        let cueHandler = self.onCaptureLifecycleCue

        // Take (read-and-clear) journal ownership: only the stop that ends an
        // active session may write the stopping/finalized states. With no
        // active session — a double stop, or cleanup after a start that failed
        // before the journal began — the token is nil and the journal store
        // drops both writes, so a previous meeting's already-handed-off
        // journal cannot be resurrected into the next launch's recovery scan.
        let journalSession = takeJournalSession()
        recordingJournal.markStopping(session: journalSession)

        // Update UI state immediately so the meeting widget unfreezes
        // before any of the slow CoreAudio teardown begins. Without this
        // dispatch, the user-visible "still spinning" state could last
        // hundreds of ms while AVAudioEngine drains in-flight callbacks
        // — the freeze Taylor reported on the meeting widget.
        DispatchQueue.main.async {
            guard self.recordingSessionGeneration == stopGeneration else {
                AppLogger.audio.info("Skipping stale stop UI reset because a newer session exists", [
                    "stopGeneration": "\(stopGeneration)",
                    "currentGeneration": "\(self.recordingSessionGeneration)"
                ])
                return
            }
            self.isRecording = false
            self.isStarting = false
            self.audioLevel = 0.0
            self.systemAudioStatus = .unknown  // Reset status when not recording
            self.stopTimer()
            self.stopWatchdog()
            self.isMicRecovering = false
            cueHandler?(.recordingStopped)
        }

        // Move the synchronous AVFoundation teardown off the main thread.
        // `engine.stop()` blocks until the audio thread has drained its
        // current buffer; if voice processing was active, the disarm step
        // can take 5–30ms more. Running these on a background queue keeps
        // the main run loop responsive so widget interactions during
        // shutdown stay clickable.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var didTeardownCurrentSession = false
            self.withAudioGraphLock {
                guard self.recordingSessionGeneration == stopGeneration else {
                    AppLogger.audio.info("Skipping stale audio graph teardown because a newer session exists", [
                        "stopGeneration": "\(stopGeneration)",
                        "currentGeneration": "\(self.recordingSessionGeneration)"
                    ])
                    return
                }
                didTeardownCurrentSession = true

                if let engineRef, let inputNodeRef {
                    AppLogger.audio.info("Stopping audio capture")
                    self.tearDownInputTapSafely(
                        engine: engineRef,
                        inputNode: inputNodeRef,
                        operation: "recording_stop"
                    )
                    self.disarmVoiceProcessing(on: inputNodeRef)
                }

                // Drop the RealtimeAGC reference so gain history doesn't
                // carry into the next recording. Safe here because the
                // engine has stopped — no more tap callbacks can fire.
                self.realtimeAGC = nil
            }

            // This closure already runs off-main, so use the synchronous system
            // capture stop. It keeps onRecordingComplete behind backend teardown
            // and avoids stale ScreenCaptureKit cleanup racing the next start.
            if didTeardownCurrentSession {
                systemCaptureRef?.stopSync()
            }

            // Coordinate file close. With the engine fully stopped above,
            // no new buffers will arrive on these queues — closing here is
            // safe. If this stop is stale, only clear the file handles that
            // belonged to the stopped generation.
            let cleanupGroup = DispatchGroup()

            cleanupGroup.enter()
            self.micAudioFileQueue.async { [weak self] in
                if let self, let micAudioFileRef {
                    if let currentMicFile = self.micAudioFile, currentMicFile === micAudioFileRef {
                        self.micAudioFile = nil
                    }
                    // Close explicitly so the WAV header is finalized here on
                    // the serial queue before cleanupGroup.notify hands the
                    // file to the merger. Waiting for deinit is racy: other
                    // closure captures can keep the writer alive past notify,
                    // and an unpatched header reads back as a zero-length file.
                    micAudioFileRef.close()
                    AppLogger.audioMic.info("Audio file closed", ["file": primaryMicURL?.lastPathComponent ?? self.micAudioFileURL?.lastPathComponent ?? "unknown"])
                }
                cleanupGroup.leave()
            }

            cleanupGroup.enter()
            self.systemAudioFileQueue.async { [weak self] in
                if let self, let systemAudioFileRef {
                    if let currentSystemFile = self.systemAudioFile, currentSystemFile === systemAudioFileRef {
                        self.systemAudioFile = nil
                    }
                    systemAudioFileRef.close()
                    AppLogger.audioSystem.info("Audio file closed", ["file": finalSystemURL?.lastPathComponent ?? "unknown"])
                }
                cleanupGroup.leave()
            }

            cleanupGroup.notify(queue: .global(qos: .utility)) { [weak self] in
                guard let self else { return }
                let finalMicURL = self.finalizeMicRecording(primaryURL: primaryMicURL, segments: micSegmentsSnapshot)
                self.recordingJournal.markFinalized(finalMicURL: finalMicURL, session: journalSession)
                DispatchQueue.main.async {
                    if self.recordingSessionGeneration == stopGeneration {
                        self.originalMicAudioFileURL = nil
                        self.micSegments = []
                        self.micAudioFileURL = finalMicURL
                    } else {
                        AppLogger.audio.info("Recording completion belongs to stale stop; preserving current capture state", [
                            "stopGeneration": "\(stopGeneration)",
                            "currentGeneration": "\(self.recordingSessionGeneration)"
                        ])
                    }
                    self.onRecordingComplete?(finalMicURL, finalSystemURL)
                }
            }
        }
    }

    /// Deliberate mid-recording engine restart so a processing-mode change
    /// (arming VPIO for the issue #500 mic boost) takes effect immediately.
    /// Reuses the device-recovery machinery; never runs recovery on the
    /// calling thread (recovery uses Thread.sleep for HAL settle).
    public func restartCaptureForProcessingChange() {
        guard isRecording, !isMicRecovering else { return }
        enableVoiceProcessing = true
        // Snapshot the generation BEFORE dispatch: stop() bumps it
        // synchronously, so a stop racing the boost aborts cleanly at
        // recovery's existing generation checks.
        let sessionGeneration = recordingSessionGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.recoverFromDeviceChange(sessionGeneration: sessionGeneration, reason: .processingChange)
        }
    }

    // MARK: - Audio Level Monitoring (no file recording)

    /// Start lightweight level metering for mic + system audio without recording to files.
    /// Used by MeetingDetector to detect bidirectional speech before full recording starts.
    /// Automatically stops when `start()` is called for full recording.
    public func startMonitoring() {
        guard !isMonitoring, !isRecording, !isStarting else { return }
        ensureCaptureInfrastructureConfigured()

        let engine: AVAudioEngine
        let inputNode: AVAudioInputNode
        do {
            (engine, inputNode) = try ensureEngineInitialized()
        } catch {
            AppLogger.audio.warning("Failed to initialize monitoring engine", ["error": error.localizedDescription])
            return
        }

        AppLogger.audio.info("Starting audio level monitoring")

        let monitorFormat = withAudioGraphLock {
            recordingFormat(for: inputNode)
        }
        guard AudioRecordingFormatPolicy.snapshot(monitorFormat) != nil else {
            AppLogger.audio.warning("Cannot start monitoring — invalid input format")
            return
        }

        do {
            try withAudioGraphLock {
                // Install mic tap for level metering only (no file writing)
                tearDownInputTapSafely(
                    engine: engine,
                    inputNode: inputNode,
                    operation: "monitoring_start"
                )
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: monitorFormat) { [weak self] buffer, _ in
                    self?.calculateLevel(buffer: buffer)
                }
                try engine.start()
            }
        } catch {
            AppLogger.audio.warning("Failed to start monitoring engine", ["error": error.localizedDescription])
            withAudioGraphLock {
                tearDownInputTapSafely(
                    engine: engine,
                    inputNode: inputNode,
                    operation: "monitoring_start_failed"
                )
            }
            return
        }

        // Start system audio capture for level metering only (no file writing)
        if let capture = systemAudioCapture {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try capture.prepare()
                    try capture.start { [weak self] systemBuffer in
                        self?.calculateSystemLevel(buffer: systemBuffer)
                    }
                    AppLogger.audioSystem.info("System audio monitoring started")
                } catch {
                    AppLogger.audioSystem.warning("System audio monitoring unavailable", ["error": error.localizedDescription])
                    // Mic monitoring still works — system audio is optional
                }
            }
        }

        DispatchQueue.main.async {
            self.isMonitoring = true
        }
    }

    /// Stop level metering. Called automatically before `start()` begins full recording.
    public func stopMonitoring() {
        guard isMonitoring else { return }

        AppLogger.audio.info("Stopping audio level monitoring")

        withAudioGraphLock {
            if let engine = engine, let inputNode = inputNode {
                tearDownInputTapSafely(
                    engine: engine,
                    inputNode: inputNode,
                    operation: "monitoring_stop"
                )
                disarmVoiceProcessing(on: inputNode)
            }

            // Monitoring shares the engine but not the AGC; drop it here so a
            // monitoring session followed by a recording session both start
            // with a fresh gain history.
            realtimeAGC = nil
        }

        systemAudioCapture?.stopSync()  // Synchronous — avoids race where delayed cleanup destroys the next recording's tap

        DispatchQueue.main.async {
            self.isMonitoring = false
            self.audioLevel = 0.0
            self.audioLevelHistory = Array(repeating: 0.0, count: 15)
            self.systemAudioLevelHistory = Array(repeating: 0.0, count: 15)
        }
    }

    deinit {
        // Remove sleep/wake observers to prevent leaks
        if let observer = sleepObserver {
            sleepWakeNotifications.center.removeObserver(observer)
        }
        if let observer = wakeObserver {
            sleepWakeNotifications.center.removeObserver(observer)
        }
        timer?.invalidate()
        watchdogTimer?.invalidate()
        systemAudioCancellable?.cancel()
        systemAudioCapture?.stopSync()

        withAudioGraphLock {
            if let engine, let inputNode {
                tearDownInputTapSafely(
                    engine: engine,
                    inputNode: inputNode,
                    operation: "deinit"
                )
            }
        }
    }
}

// MARK: - AudioCaptureEngine conformance
// Empty extension — protocol signatures match Audio's existing public API exactly.
// Added as part of Step 8 protocol wiring (merge-plan §5.1).

extension Audio: AudioCaptureEngine {}

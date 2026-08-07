import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine

public enum RecordingStopFinalizationDisposition: Sendable, Equatable {
    case finalized
    case journalRecoveryOwned
}

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
    case meetingRouteStabilityWarning(CaptureRouteStabilizationOutcome)
}

/// Coarse, privacy-safe result of the one bounded input-route stabilization
/// attempt allowed during a meeting. The value is also safe to expose to host
/// UI and analytics because it contains no device identity.
public enum CaptureRouteStabilizationOutcome: String, Equatable, Sendable {
    case notNeeded = "not_needed"
    case switchedToBuiltIn = "switched_to_built_in"
    case builtInUnavailable = "built_in_unavailable"
    case switchFailed = "switch_failed"
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
    //
    // Pinned, not unified: mic and system audio each track "how quiet is it"
    // as parallel state (this block + `systemAudioSilenceStart`/
    // `systemAudioStatus`/`systemAudioSilenceThreshold` further down, plus
    // the mirrored `calculateLevel`/`calculateSystemLevel` and
    // `updateSilenceTracking`/`updateSystemAudioSilenceTracking` pairs in
    // AudioLevelMonitor.swift). They read genuinely different signals
    // (normalized RMS vs. linear peak), use different thresholds and output
    // shapes (continuous Bool+TimeInterval here vs. a hysteresis-gated
    // `SystemAudioStatus` enum for system), and the mic path runs
    // synchronously on the AVAudioEngine tap callback thread under
    // `micLevelPublishLock`/`systemLevelLock` — see the threading note above
    // `levelPublishInterval`. Collapsing both into one generic track-state
    // type would mean generalizing over that metric/threshold/output
    // divergence inside RT-adjacent, lock-guarded code, which is exactly the
    // "touches RT code non-trivially" case call out for this cleanup pass —
    // left alone rather than risking a behavior change here.
    @Published public var silenceDuration: TimeInterval = 0.0  // How long we've been in silence
    @Published public var isSilent: Bool = false  // True when audio below threshold
    let silenceThreshold: Float = 0.02  // Audio level below this = silence
    var lastNonSilentTime: Date?

    // Audio file URLs - returned when recording stops
    @Published public var micAudioFileURL: URL?
    @Published public var systemAudioFileURL: URL?

    /// True once the microphone tap has actually delivered its first nonempty
    /// buffer for the current recording. A mic WAV can be created before the
    /// input tap has delivered anything, so meeting readiness must not treat a
    /// file URL or a running engine as proof that microphone capture works.
    /// The flag is generation-guarded from the mic callback and reset for each
    /// fresh recording start.
    @Published public internal(set) var micAudioStreaming: Bool = false

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
    private struct StoppingRecordingFinalization {
        let journalSession: MeetingRecordingJournalSession?
    }
    struct StoppedMicRecordingFinalization {
        let micURL: URL?
        let disposition: RecordingStopFinalizationDisposition
    }
    private var stoppingRecordingFinalizations: [UInt64: StoppingRecordingFinalization] = [:]
    private let stoppingJournalSessionsLock = NSLock()

    func retainStoppingJournalSession(
        _ session: MeetingRecordingJournalSession?,
        generation: UInt64
    ) {
        stoppingJournalSessionsLock.lock()
        stoppingRecordingFinalizations[generation] = StoppingRecordingFinalization(
            journalSession: session
        )
        stoppingJournalSessionsLock.unlock()
    }

    private func takeStoppingRecordingFinalization(
        generation: UInt64
    ) -> StoppingRecordingFinalization? {
        stoppingJournalSessionsLock.lock()
        defer { stoppingJournalSessionsLock.unlock() }
        return stoppingRecordingFinalizations.removeValue(forKey: generation)
    }

    /// Claims this generation's finalizer before it mutates any recording
    /// files. If recovery already took ownership, leave every segment and
    /// merged artifact untouched for that canonical recovery path.
    func finalizeStoppedMicRecordingResult(
        primaryURL: URL?,
        segments: [MicRecordingSegment],
        generation: UInt64
    ) -> StoppedMicRecordingFinalization {
        guard let finalization = takeStoppingRecordingFinalization(generation: generation) else {
            AppLogger.audioMic.info("Skipped abandoned mic finalization owned by recovery", [
                "stopGeneration": "\(generation)"
            ])
            return StoppedMicRecordingFinalization(
                micURL: nil,
                disposition: .journalRecoveryOwned
            )
        }
        let finalMicURL = finalizeMicRecording(primaryURL: primaryURL, segments: segments)
        recordingJournal.markFinalized(
            finalMicURL: finalMicURL,
            session: finalization.journalSession
        )
        return StoppedMicRecordingFinalization(
            micURL: finalMicURL,
            disposition: .finalized
        )
    }

    /// The host no longer retains a completion callback for this stopped
    /// generation. Atomically invalidate its journal session before releasing
    /// the live claim so recovery becomes the only remaining writer.
    @discardableResult
    public func abandonRecordingJournalFinalization(
        forStopGeneration generation: UInt64
    ) -> Bool {
        stoppingJournalSessionsLock.lock()
        guard let finalization = stoppingRecordingFinalizations.removeValue(forKey: generation) else {
            stoppingJournalSessionsLock.unlock()
            return false
        }
        if let session = finalization.journalSession {
            recordingJournal.abandonFinalization(session: session)
        }
        stoppingJournalSessionsLock.unlock()
        return true
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

    /// Records a system-audio-side bounded-recovery attempt (SCK restarting
    /// its ScreenCaptureKit stream after a buffer stall or stream stop) into
    /// the SAME counter mic-path device switches use, so system-audio
    /// dropouts count toward `RecordingHealthInfo.captureQuality` instead of
    /// being invisible to it. Wired from `wireSystemAudioStatusPublisher`'s
    /// `recoveryEventPublisher` subscription, which already runs on main.
    func recordSystemAudioDeviceSwitch() {
        guard isRecording else { return }
        incrementDeviceSwitchCount()
    }

    /// Records a system-audio recovery gap (bounded SCK recovery succeeded
    /// after `duration` seconds of stalled/stopped capture), mirroring the
    /// mic path's `AudioGap` entries into the SAME `recordingGaps` array so
    /// system-audio interruptions show up in saved transcript health
    /// metadata the same way mic-side gaps already do.
    func recordSystemAudioGap(duration: TimeInterval) {
        guard isRecording else { return }
        appendRecordingGap(AudioGap(
            start: Date(timeIntervalSinceNow: -duration),
            duration: duration,
            reason: "System audio reconnect"
        ))
    }

    /// Commit recovery artifacts only while the recovery still owns the
    /// current recording generation. The generation lock also blocks a
    /// concurrent stop/start from advancing the session between the check and
    /// the array/journal mutations.
    @discardableResult
    func finalizeMicRecoveryArtifacts(
        gap: AudioGap,
        recoverySegment: MicRecordingSegment?,
        sessionGeneration: UInt64
    ) -> Bool {
        recordingSessionGenerationLock.lock()
        defer { recordingSessionGenerationLock.unlock() }
        guard recordingSessionGenerationEpoch.snapshot().rawValue == sessionGeneration else { return false }

        appendRecordingGap(gap)
        if let recoverySegment {
            appendMicSegment(recoverySegment)
        }
        recoveryAttemptCount = 0
        return true
    }

    /// Count of device switches during this recording
    /// Thread-safe: reset on main thread; incremented from BOTH the mic-path
    /// background recovery queue and the SCK recovery-event subscription on
    /// main. The get/set pair above is only safe for whole-value resets
    /// (`deviceSwitchCount = 0`) — a `+=`-style increment through it does a
    /// get and a set as two separate lock acquisitions, so two concurrent
    /// incrementers can race and drop an update. `incrementDeviceSwitchCount()`
    /// does the read-modify-write inside ONE lock acquisition; every
    /// increment site must go through it instead of `deviceSwitchCount += 1`.
    private var _deviceSwitchCount: Int = 0
    private let deviceSwitchCountLock = NSLock()
    var deviceSwitchCount: Int {
        get { deviceSwitchCountLock.lock(); defer { deviceSwitchCountLock.unlock() }; return _deviceSwitchCount }
        set { deviceSwitchCountLock.lock(); defer { deviceSwitchCountLock.unlock() }; _deviceSwitchCount = newValue }
    }

    /// Atomically increments and returns the new `deviceSwitchCount`. Use
    /// this instead of `deviceSwitchCount += 1` at every increment site —
    /// the mic path's `recoverFromDeviceChange` and the SCK-path
    /// `recordSystemAudioDeviceSwitch()` below can run concurrently on
    /// different queues.
    @discardableResult
    func incrementDeviceSwitchCount() -> Int {
        deviceSwitchCountLock.lock()
        defer { deviceSwitchCountLock.unlock() }
        _deviceSwitchCount += 1
        return _deviceSwitchCount
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
    //
    // This is the cross-time cache: it is what makes VPIO state visible to
    // work that happens well after the arm call returned (disarm at stop,
    // live diagnostics snapshots, log lines) where no synchronous return
    // value is available. Callers that run immediately alongside
    // `armVoiceProcessing(on:)` — same lock scope, nothing intervening —
    // should prefer its returned `VoiceProcessingBindResult` instead of
    // re-reading this var, so route-identity decisions have exactly one
    // source of truth for "what did the arm call just observe." See
    // `makeReadyMeetingInputGraph` for the canonical example.
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

    // Mic recovery ownership (prevents concurrent recovery attempts across
    // recording-session boundaries). The owner stays set until the background
    // recovery actually returns; a fast stop/start cannot clear it from under
    // the older recovery with an unscoped Bool assignment.
    private var _micRecoverySessionGeneration: UInt64?
    private let micRecoveryLock = NSLock()
    var isMicRecovering: Bool {
        get {
            micRecoveryLock.lock()
            defer { micRecoveryLock.unlock() }
            return _micRecoverySessionGeneration != nil
        }
    }

    @discardableResult
    func beginMicRecovery(for sessionGeneration: UInt64) -> Bool {
        micRecoveryLock.lock()
        defer { micRecoveryLock.unlock() }
        guard _micRecoverySessionGeneration == nil else { return false }
        _micRecoverySessionGeneration = sessionGeneration
        return true
    }

    func endMicRecovery(for sessionGeneration: UInt64) {
        micRecoveryLock.lock()
        defer { micRecoveryLock.unlock() }
        guard _micRecoverySessionGeneration == sessionGeneration else { return }
        _micRecoverySessionGeneration = nil
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

    // Meeting input is selected once at start and then pinned for the session.
    // Recovery may make one bounded built-in fallback after a real Bluetooth
    // mic outage, but it must never follow a changing system default forever.
    private var _meetingInputSelection: MeetingInputDeviceSelection?
    private var _meetingRouteStabilizationAttemptCount = 0
    private var _meetingRouteStabilizationOutcome: CaptureRouteStabilizationOutcome = .notNeeded
    private var _meetingRouteStabilityWarningEmitted = false
    private let meetingRouteStateLock = NSLock()

    var meetingInputSelectionReasonValue: String {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        return _meetingInputSelection?.reason.rawValue ?? "unavailable"
    }

    var meetingRouteStabilizationAttemptBucket: String {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        switch _meetingRouteStabilizationAttemptCount {
        case 0: return "0"
        case 1: return "1"
        case 2...3: return "2_3"
        case 4...9: return "4_9"
        default: return "10_plus"
        }
    }

    var meetingRouteStabilizationOutcomeValue: String {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        return _meetingRouteStabilizationOutcome.rawValue
    }

    var meetingRouteStabilityWarningEmitted: Bool {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        return _meetingRouteStabilityWarningEmitted
    }

    func meetingInputIsBluetooth() -> Bool {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        guard let selection = _meetingInputSelection else { return false }
        return selection.selectedInput.transport == .bluetooth
            || selection.selectedInput.transport == .bluetoothLE
    }

    func meetingInputSelectionSnapshot() -> MeetingInputDeviceSelection? {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        return _meetingInputSelection
    }

    func setMeetingInputSelection(_ selection: MeetingInputDeviceSelection) {
        meetingRouteStateLock.lock()
        _meetingInputSelection = selection
        meetingRouteStateLock.unlock()
    }

    func recordMeetingRouteStabilizationAttempt(
        outcome: CaptureRouteStabilizationOutcome
    ) {
        meetingRouteStateLock.lock()
        _meetingRouteStabilizationAttemptCount += 1
        _meetingRouteStabilizationOutcome = outcome
        meetingRouteStateLock.unlock()
    }

    func setMeetingRouteStabilizationOutcome(
        _ outcome: CaptureRouteStabilizationOutcome
    ) {
        meetingRouteStateLock.lock()
        _meetingRouteStabilizationOutcome = outcome
        meetingRouteStateLock.unlock()
    }

    func resetMeetingRouteState() {
        meetingRouteStateLock.lock()
        _meetingInputSelection = nil
        _meetingRouteStabilizationAttemptCount = 0
        _meetingRouteStabilizationOutcome = .notNeeded
        _meetingRouteStabilityWarningEmitted = false
        meetingRouteStateLock.unlock()
    }

    // One-shot diagnostics marker for the bounded start-time fallback that
    // retries the meeting mic graph without Apple voice processing after VPIO
    // was requested but did not become active. Separate from
    // `resetMeetingRouteState()` on purpose: the retry loop resets route state
    // mid-build and device recovery resets it mid-session, but this marker
    // must survive until the next `prepareForNewRecordingStart()` so the
    // start-failed/started diagnostics snapshot can report whether the
    // fallback engaged.
    private var _voiceProcessingStartFallback: VoiceProcessingStartFallbackState = .none
    private let voiceProcessingStartFallbackLock = NSLock()

    var voiceProcessingStartFallbackValue: String {
        voiceProcessingStartFallbackLock.lock()
        defer { voiceProcessingStartFallbackLock.unlock() }
        return _voiceProcessingStartFallback.rawValue
    }

    func recordVoiceProcessingStartFallback(_ state: VoiceProcessingStartFallbackState) {
        voiceProcessingStartFallbackLock.lock()
        _voiceProcessingStartFallback = state
        voiceProcessingStartFallbackLock.unlock()
    }

    func emitMeetingRouteStabilityWarningIfNeeded(
        outcome: CaptureRouteStabilizationOutcome
    ) {
        guard outcome != .notNeeded else { return }

        meetingRouteStateLock.lock()
        guard !_meetingRouteStabilityWarningEmitted else {
            meetingRouteStateLock.unlock()
            return
        }
        _meetingRouteStabilityWarningEmitted = true
        meetingRouteStateLock.unlock()

        onCaptureLifecycleCue?(.meetingRouteStabilityWarning(outcome))
    }
    // Recording session generation - increments on each start/stop so delayed
    // recovery work from an old session cannot restart a newer one. The epoch
    // stays lock-confined because its host is accessed from audio and recovery
    // threads.
    private var recordingSessionGenerationEpoch = SupersessionEpoch()
    private let recordingSessionGenerationLock = NSLock()
    var recordingSessionGeneration: UInt64 {
        get {
            recordingSessionGenerationLock.lock()
            defer { recordingSessionGenerationLock.unlock() }
            return recordingSessionGenerationEpoch.snapshot().rawValue
        }
        set {
            recordingSessionGenerationLock.lock()
            defer { recordingSessionGenerationLock.unlock() }
            recordingSessionGenerationEpoch = SupersessionEpoch(testRawValue: newValue)
        }
    }

    @discardableResult
    private func beginRecordingSessionGeneration() -> UInt64 {
        recordingSessionGenerationLock.lock()
        defer { recordingSessionGenerationLock.unlock() }
        return recordingSessionGenerationEpoch.begin().rawValue
    }

    func predictedNextRecordingSessionGeneration() -> UInt64 {
        recordingSessionGenerationLock.lock()
        defer { recordingSessionGenerationLock.unlock() }
        return recordingSessionGenerationEpoch.predictedNext().rawValue
    }
    let maxRecoveryAttempts = AudioRecoveryTuning.Mic.maxRecoveryAttempts
    let recoveryCooldown: TimeInterval = AudioRecoveryTuning.Mic.recoveryCooldownSeconds  // Min seconds between recovery attempts

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
    // Pinned alongside the level/silence duplication noted above `silenceDuration`:
    // mic and system counters are parallel state with parallel
    // recordMicWriteFailure/recordSystemWriteFailure handlers in
    // AudioFileManager.swift, differing only in messaging and which stop
    // path they call. Left as-is for the same reason (RT-adjacent surface,
    // deferred rather than forced for this pass).
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
    private let systemAudioCaptureStateLock = NSLock()
    private var _systemAudioCapture: (any SystemAudioCaptureEngine & Sendable)?
    var systemAudioCapture: (any SystemAudioCaptureEngine & Sendable)? {
        get {
            systemAudioCaptureStateLock.lock()
            defer { systemAudioCaptureStateLock.unlock() }
            return _systemAudioCapture
        }
        set {
            systemAudioCaptureStateLock.lock()
            _systemAudioCapture = newValue
            systemAudioCaptureStateLock.unlock()
        }
    }
    private let systemAudioCaptureFactory:
        () -> (any SystemAudioCaptureEngine & Sendable)?
    private let systemAudioMonitoringAttemptLock = NSLock()
    private var systemAudioMonitoringAttempt: SystemAudioCaptureStartAttempt?

    // Audio file recording
    var systemAudioCaptureAttemptOwnership =
        SystemAudioCaptureAttemptOwnership<SystemAudioCaptureStartAttempt, AVAudioFile>()
    let systemAudioSetupQueue = DispatchQueue(
        label: "SystemAudioSetup",
        qos: .userInitiated,
        attributes: .concurrent
    )
    var micAudioFileOwnership = MicWriterOwnership<AVAudioFile>()
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

    // Time-gate for @Published level updates. Mic buffers land ~12x/s and
    // system buffers faster still; every main-thread publish fans out through
    // the capture bridge into SwiftUI observers, so levels only publish when
    // at least `levelPublishInterval` has passed since the last publish. The
    // next gated buffer always carries the freshest level, and stop/reset
    // paths write the published properties directly on main (bypassing the
    // gate), so a final level of 0 still lands when capture ends.
    // Timestamps use monotonic CACurrentMediaTime — a wall-clock jump must
    // not wedge the gate shut. Protected by their locks — accessed from
    // tap and I/O callback threads.
    static let levelPublishInterval: CFTimeInterval = 0.15
    var lastMicLevelPublishTime: CFTimeInterval = 0
    let micLevelPublishLock = NSLock()
    var lastSystemLevelPublishTime: CFTimeInterval = 0
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

    // Track nonempty mic buffers separately so the first-frame readiness
    // latch only schedules one main-thread publication per recording.
    private var _micBufferCount: Int = 0
    private let micBufferCountLock = NSLock()
    var micBufferCount: Int {
        get {
            micBufferCountLock.lock()
            defer { micBufferCountLock.unlock() }
            return _micBufferCount
        }
        set {
            micBufferCountLock.lock()
            defer { micBufferCountLock.unlock() }
            _micBufferCount = newValue
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
    // Recovery/health event observation (device-switch + gap parity with the
    // mic path). Separate from `systemAudioCancellable` so re-wiring one
    // subscription on a new capture attempt doesn't need to touch the other.
    private var systemAudioRecoveryEventCancellable: AnyCancellable?
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
    /// Generation-tagged completion callback used by hosts that can overlap a
    /// timed-out stop with a newer recording. The legacy callback remains for
    /// embedders that do not need stale-session filtering.
    public var onRecordingCompleteWithGeneration: ((UInt64, URL?, URL?, RecordingStopFinalizationDisposition) -> Void)?

    /// Monotonic capture-session generation visible to host lifecycle bridges.
    /// It changes synchronously at each start/stop boundary.
    public var currentRecordingSessionGeneration: UInt64 {
        recordingSessionGeneration
    }

    /// Explicit discard owns the current journal's complete segment inventory,
    /// including the no-callback case where the returned URL tuple is empty.
    public func discardCurrentRecordingArtifacts(micAudioURL: URL?, systemAudioURL: URL?) {
        recordingJournal.discardCurrentRecordingArtifacts(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            allowedRoot: paths.audioCaptures
        )
    }

    /// A late generation-tagged callback has no access to the current journal;
    /// delete only its validated finalized files and matching on-disk journal.
    public func discardFinalizedRecordingArtifacts(micAudioURL: URL?, systemAudioURL: URL?) {
        MeetingRecordingJournalStore.discardRecordingArtifacts(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            allowedRoots: [paths.audioCaptures]
        )
    }

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
    // from CoreAudio, in parallel with the WAV file writes. The app uses them
    // for live meeting transcription and to let dictation borrow the active
    // meeting microphone without starting a second audio engine.
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
        self.systemAudioCaptureFactory = { SCKAudioCapture() }
    }

    init(
        paths: CoreStoragePaths = .default,
        systemAudioCaptureForTesting systemAudioCapture: (any SystemAudioCaptureEngine & Sendable)?,
        systemAudioCaptureFactoryForTesting systemAudioCaptureFactory:
            (() -> (any SystemAudioCaptureEngine & Sendable)?)? = nil,
        sleepWakeNotifications: AudioSleepWakeNotifications = .macOSWorkspace
    ) {
        self.paths = paths
        self.sleepWakeNotifications = sleepWakeNotifications
        self.recordingJournal = MeetingRecordingJournalStore(directory: paths.audioCaptures)
        self._systemAudioCapture = systemAudioCapture
        self.systemAudioCaptureFactory =
            systemAudioCaptureFactory ?? { systemAudioCapture }
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
        guard let capture = systemAudioCaptureFactory() else { return }
        systemAudioCapture = capture
        wireSystemAudioStatusPublisher(from: capture)
        installWorkspaceSleepWakeObservers()
    }

    func makeSystemAudioCaptureForRecordingAttempt()
        -> (any SystemAudioCaptureEngine & Sendable)? {
        guard let capture = systemAudioCaptureFactory() else { return nil }
        systemAudioCapture = capture
        wireSystemAudioStatusPublisher(from: capture)
        return capture
    }

    func replaceSystemAudioMonitoringAttempt(
        with attempt: SystemAudioCaptureStartAttempt?
    ) -> SystemAudioCaptureStartAttempt? {
        systemAudioMonitoringAttemptLock.lock()
        let previous = systemAudioMonitoringAttempt
        systemAudioMonitoringAttempt = attempt
        systemAudioMonitoringAttemptLock.unlock()
        return previous
    }

    private func currentSystemAudioMonitoringAttemptIs(
        _ attempt: SystemAudioCaptureStartAttempt
    ) -> Bool {
        systemAudioMonitoringAttemptLock.lock()
        defer { systemAudioMonitoringAttemptLock.unlock() }
        return systemAudioMonitoringAttempt === attempt
    }

    private func wireSystemAudioStatusPublisher(from capture: any SystemAudioCaptureEngine) {
        systemAudioCancellable = capture.errorMessagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorMessage in
                self?.updateSystemAudioStatus(fromError: errorMessage)
            }
        systemAudioRecoveryEventCancellable = capture.recoveryEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .deviceSwitch:
                    self.recordSystemAudioDeviceSwitch()
                case .gap(let duration):
                    self.recordSystemAudioGap(duration: duration)
                }
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

                    // Give system audio the same proactive post-wake recovery
                    // opportunity as the mic path, instead of only relying on
                    // SCK's own buffer-stall watchdog (which can take up to
                    // `AudioRecoveryTuning.SystemAudio.stallTimeoutSeconds`
                    // to notice). No-ops for backends without bounded
                    // recovery (see `SystemAudioCaptureEngine`'s default).
                    self.systemAudioCapture?.recoverAfterSystemWake()
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

    /// Create a detached mic graph instead of inheriting one used by
    /// monitoring or a failed device switch. The new graph is not published
    /// on `self` until its device and format are validated for the current
    /// recording generation, so a concurrent Stop cannot miss a newly claimed
    /// audio device.
    func makeDetachedFreshInputEngine() -> (AVAudioEngine, AVAudioInputNode) {
        if let currentEngine = engine {
            if currentEngine.isRunning, let currentInputNode = inputNode {
                tearDownInputTapSafely(
                    engine: currentEngine,
                    inputNode: currentInputNode,
                    operation: "start_recording_replace_graph"
                )
            }
            if let currentInputNode = inputNode {
                disarmVoiceProcessing(
                    on: currentInputNode,
                    reason: "start_recording_replace_graph"
                )
            }
            currentEngine.reset()
            engine = nil
            inputNode = nil
        }

        let freshEngine = AVAudioEngine()
        let freshInputNode = freshEngine.inputNode
        voiceProcessingEnabled = false
        AppLogger.audioMic.info("Created detached fresh microphone graph")
        return (freshEngine, freshInputNode)
    }

    func discardUnstartedInputGraph(
        engine discardedEngine: AVAudioEngine,
        inputNode discardedInputNode: AVAudioInputNode,
        operation: String
    ) {
        let ownsPublishedGraph = engine === discardedEngine
        if discardedEngine.isRunning {
            tearDownInputTapSafely(
                engine: discardedEngine,
                inputNode: discardedInputNode,
                operation: operation
            )
        }
        if ownsPublishedGraph {
            disarmVoiceProcessing(on: discardedInputNode, reason: operation)
        } else if discardedInputNode.isVoiceProcessingEnabled {
            do {
                try discardedInputNode.setVoiceProcessingEnabled(false)
            } catch {
                AppLogger.audioMic.warning("Detached voice processing disable failed", [
                    "operation": operation,
                    "error": error.localizedDescription
                ])
            }
        }
        discardedEngine.reset()
        if ownsPublishedGraph {
            engine = nil
            inputNode = nil
            voiceProcessingEnabled = false
        } else if engine == nil {
            voiceProcessingEnabled = false
        }
    }

    struct PreparedMeetingInputGraph {
        let engine: AVAudioEngine
        let inputNode: AVAudioInputNode
        let recordingFormat: AVAudioFormat
        let recordingSnapshot: AudioRecordingFormatSnapshot
    }

    /// Build and validate a meeting microphone graph. A failed device bind
    /// taints the entire graph: CoreAudio may expose the requested device ID
    /// while retaining the previous device's format and delivering no frames.
    /// Each retry therefore starts from a new AVAudioEngine/input node.
    func makeReadyMeetingInputGraph(
        operation: String,
        resetMeetingSelectionBeforeRetry: Bool,
        sessionGeneration: UInt64,
        routeWasUnstable: Bool = false
    ) throws -> PreparedMeetingInputGraph {
        var lastError: Error?
        // Result of the most recent `armVoiceProcessing` call, threaded out of
        // the attempt so the retry can tell "VPIO was requested but did not
        // become active" apart from every other first-attempt failure.
        var lastAttemptVoiceProcessingActive: Bool?
        var voiceProcessingFallbackEngaged = false

        for attempt in 0..<2 {
            guard sessionGeneration == recordingSessionGeneration else {
                throw AudioCaptureStaleSessionError()
            }

            if attempt > 0 {
                // Bounded, meeting-only start fallback: when the user asked
                // for Apple voice processing but arming it did not take, the
                // failed wrap can leave the fresh input node with an
                // untrustworthy device identity, so re-arming identically just
                // fails the retry the same way and the start dies looking like
                // a microphone problem. Run the one existing retry on the
                // standard non-VPIO path instead. Permission gating and the
                // mic/system readiness latches downstream are untouched.
                if VoiceProcessingStartFallbackPolicy.shouldRetryWithoutVoiceProcessing(
                    voiceProcessingRequested: enableVoiceProcessing,
                    previousAttemptVoiceProcessingActive: lastAttemptVoiceProcessingActive,
                    fallbackAlreadyEngaged: voiceProcessingFallbackEngaged
                ) {
                    voiceProcessingFallbackEngaged = true
                    recordVoiceProcessingStartFallback(.attempted)
                    AppLogger.audioMic.warning("Voice processing was requested but did not become active; retrying capture start without it", [
                        "operation": operation,
                        "error": lastError?.localizedDescription ?? "unknown"
                    ])
                }
                if resetMeetingSelectionBeforeRetry {
                    resetMeetingRouteState()
                }
                // Let CoreAudio settle without blocking Stop's graph teardown.
                Thread.sleep(forTimeInterval: 0.3)
            }

            guard sessionGeneration == recordingSessionGeneration else {
                throw AudioCaptureStaleSessionError()
            }

            do {
                let preparedGraph = try withAudioGraphLock { () throws -> PreparedMeetingInputGraph in
                    guard sessionGeneration == recordingSessionGeneration else {
                        throw AudioCaptureStaleSessionError()
                    }

                    let (freshEngine, freshInputNode) = makeDetachedFreshInputEngine()
                    do {
                        let attemptOperation = attempt == 0 ? operation : "\(operation)_retry"
                        let selectionOutcome = applyMeetingInputDevice(
                            to: freshInputNode,
                            operation: attemptOperation,
                            routeWasUnstable: routeWasUnstable
                        )
                        guard !MeetingInputDeviceSelectionPolicy.shouldAbortMeetingStart(
                            after: selectionOutcome
                        ) else {
                            throw NSError(
                                domain: "Audio",
                                code: 4,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "Could not safely switch microphones. Check your input device and try again."
                                ]
                            )
                        }

                        // Verify the selected physical microphone before VPIO
                        // replaces the node's device identity with its private
                        // wrapper. The wrapper ID is not a reliable indication
                        // of which physical input CoreAudio already bound.
                        // `armVoiceProcessing` returns both the pre-wrap device
                        // ID and the resulting VPIO state as one atomic value,
                        // so route readiness and format selection below thread
                        // that same value through instead of separately
                        // capturing the device ID beforehand and re-reading
                        // the ambient `voiceProcessingEnabled` cache after.
                        let selection = meetingInputSelectionSnapshot()
                        let voiceProcessingBind = armVoiceProcessing(
                            on: freshInputNode,
                            suppressedByStartFallback: voiceProcessingFallbackEngaged
                        )
                        lastAttemptVoiceProcessingActive = voiceProcessingBind.enabled
                        let recordingFormat = self.recordingFormat(
                            for: freshInputNode,
                            voiceProcessingEnabled: voiceProcessingBind.enabled
                        )
                        guard let recordingSnapshot = AudioRecordingFormatPolicy.snapshot(recordingFormat) else {
                            throw NSError(
                                domain: "Audio",
                                code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "Invalid input format"]
                            )
                        }

                        let selectedNominalRate = selection.flatMap {
                            try? $0.selectedInput.id.readNominalSampleRate()
                        }
                        let actualInputDeviceID = freshInputNode.auAudioUnit.deviceID
                        let routeReadiness = MeetingInputDeviceSelectionPolicy.routeReadiness(
                            selection: selection,
                            boundInputDeviceIDBeforeVoiceProcessing: voiceProcessingBind.boundInputDeviceIDBeforeWrap,
                            actualInputDeviceID: actualInputDeviceID,
                            capturedSampleRate: recordingSnapshot.sampleRate,
                            selectedNominalSampleRate: selectedNominalRate,
                            voiceProcessingEnabled: voiceProcessingBind.enabled
                        )
                        guard routeReadiness == .ready else {
                            AppLogger.audioMic.warning("Meeting microphone route did not settle", [
                                "attempt": "\(attempt + 1)",
                                "operation": operation,
                                "outcome": routeReadiness.rawValue,
                                "capturedRate": "\(recordingSnapshot.sampleRate)",
                                "selectedNominalRate": selectedNominalRate.map { "\($0)" } ?? "unknown"
                            ])
                            throw NSError(
                                domain: "Audio",
                                code: 5,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "The microphone route did not become ready. Check your input device and try again."
                                ]
                            )
                        }

                        guard sessionGeneration == recordingSessionGeneration else {
                            throw AudioCaptureStaleSessionError()
                        }

                        // Publish only after this detached graph is fully
                        // validated for the still-current recording session.
                        engine = freshEngine
                        inputNode = freshInputNode
                        return PreparedMeetingInputGraph(
                            engine: freshEngine,
                            inputNode: freshInputNode,
                            recordingFormat: recordingFormat,
                            recordingSnapshot: recordingSnapshot
                        )
                    } catch {
                        discardUnstartedInputGraph(
                            engine: freshEngine,
                            inputNode: freshInputNode,
                            operation: "\(operation)_discard_attempt"
                        )
                        throw error
                    }
                }

                guard sessionGeneration == recordingSessionGeneration else {
                    withAudioGraphLock {
                        discardUnstartedInputGraph(
                            engine: preparedGraph.engine,
                            inputNode: preparedGraph.inputNode,
                            operation: "\(operation)_discard_stale"
                        )
                    }
                    throw AudioCaptureStaleSessionError()
                }
                return preparedGraph
            } catch {
                if error is AudioCaptureStaleSessionError {
                    throw error
                }
                lastError = error
                AppLogger.audioMic.warning("Meeting microphone graph attempt failed", [
                    "attempt": "\(attempt + 1)",
                    "operation": operation,
                    "error": error.localizedDescription
                ])
            }
        }

        if meetingRouteStabilizationOutcomeValue == CaptureRouteStabilizationOutcome.switchFailed.rawValue {
            emitMeetingRouteStabilityWarningIfNeeded(outcome: .switchFailed)
        }
        let terminalError = lastError ?? NSError(
            domain: "Audio",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "The microphone route did not become ready."]
        )
        guard voiceProcessingFallbackEngaged else {
            throw terminalError
        }
        // Both the VPIO attempt and the non-VPIO fallback failed. Name the
        // voice-processing angle so the failure stops classifying as a bare
        // microphone/permission dead end, and keep the fallback attempt's real
        // error both in the message and as the underlying error.
        throw NSError(
            domain: "Audio",
            code: 7,
            userInfo: [
                NSLocalizedDescriptionKey: "Apple voice processing could not be activated, and the standard microphone path also failed: \(terminalError.localizedDescription)",
                NSUnderlyingErrorKey: terminalError
            ]
        )
    }

    /// Format the mic tap will actually deliver. With VPIO enabled the tap
    /// receives the VPIO output (mono Float32 at the unit's preferred rate),
    /// not the raw hardware format. Without VPIO we keep using the hardware
    /// format read on bus 1 so Bluetooth devices keep working.
    ///
    /// `voiceProcessingEnabled` lets a caller that just received a
    /// `VoiceProcessingBindResult` from `armVoiceProcessing(on:)` pass that
    /// exact value through instead of re-reading the ambient cache; callers
    /// with no bind result in scope (e.g. monitoring, which never arms VPIO)
    /// fall back to the cache as before.
    func recordingFormat(
        for inputNode: AVAudioInputNode,
        voiceProcessingEnabled overrideVoiceProcessingEnabled: Bool? = nil
    ) -> AVAudioFormat {
        if overrideVoiceProcessingEnabled ?? voiceProcessingEnabled {
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

    /// Atomic snapshot returned by `armVoiceProcessing(on:)`. Pairs the
    /// physical input device this call observed BEFORE it could wrap the
    /// node in VPIO's private aggregate device with whether VPIO ended up
    /// enabled. `MeetingInputDeviceSelectionPolicy.routeReadiness` treats
    /// `boundInputDeviceIDBeforeWrap` as its only pre-wrap device-identity
    /// input — it must never be re-derived from the node after arming, since
    /// the node's reported device ID is no longer trustworthy once VPIO is
    /// active (see the 1.1.52 fix for the field bug this caused with
    /// third-party HAL drivers).
    struct VoiceProcessingBindResult: Equatable, Sendable {
        let boundInputDeviceIDBeforeWrap: AudioDeviceID
        let enabled: Bool
    }

    /// Pure mirror of what `disarmVoiceProcessing(on:reason:)` leaves in
    /// `voiceProcessingEnabled` once it returns, as a function of whether the
    /// engine was running at call time and what the cache held beforehand.
    /// `disarmVoiceProcessing` itself needs a live `AVAudioInputNode` and so
    /// is not exercised directly by a unit test (this test target does not
    /// construct real `AVAudioEngine` instances); `armVoiceProcessing`'s
    /// preference-off branch instead calls this pure decision to compute the
    /// `VoiceProcessingBindResult` it returns, so `VoiceProcessingDisarmOutcomeTests`
    /// pins the real invariant the branch depends on:
    ///
    /// - `disarmVoiceProcessing` returns immediately, before touching
    ///   `voiceProcessingEnabled` at all, whenever the engine is running
    ///   (VPIO cannot be toggled mid-graph) — the cache is left exactly as
    ///   it was.
    /// - In every other path through `disarmVoiceProcessing` (the
    ///   already-disabled early return, and the full disable attempt on
    ///   either success or failure), it unconditionally ends with
    ///   `voiceProcessingEnabled = false`.
    ///
    /// A hard-coded `false` here — instead of this decision — previously
    /// broke this exact scenario: the opt-in preference toggled off
    /// mid-session while VPIO was still armed and the engine running, which
    /// on `main` left the ambient `voiceProcessingEnabled` cache at `true`
    /// (disarm's early return above never clears it) and so fed `true` into
    /// `recordingFormat`/`routeReadiness` — the exact path the 1.1.52 fix
    /// hardened. Keep this in sync with `disarmVoiceProcessing` if its
    /// branching ever changes.
    static func voiceProcessingEnabledAfterDisarmAttempt(
        engineIsRunning: Bool,
        priorVoiceProcessingEnabled: Bool
    ) -> Bool {
        engineIsRunning ? priorVoiceProcessingEnabled : false
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
    ///
    /// Returns a `VoiceProcessingBindResult` pairing the physical device ID
    /// this call observed BEFORE any branch below could wrap the node in
    /// VPIO's private aggregate device, with whether VPIO ended up active.
    /// Callers that need both facts right after arming (route readiness,
    /// format selection) should consume this return value directly rather
    /// than separately reading `inputNode.auAudioUnit.deviceID` beforehand
    /// and `voiceProcessingEnabled` afterward — those two reads are only
    /// guaranteed to agree with this call's outcome because nothing runs
    /// between them, which is exactly the invariant this return value now
    /// encodes explicitly instead of leaving implicit.
    /// `suppressedByStartFallback` forces the preference-off branch for one
    /// graph-build retry after VPIO was requested but did not become active
    /// (see `VoiceProcessingStartFallbackPolicy`). It never mutates
    /// `enableVoiceProcessing`, so diagnostics keep reporting the user's real
    /// request and the next recording start re-reads the preference normally.
    @discardableResult
    func armVoiceProcessing(
        on inputNode: AVAudioInputNode,
        suppressedByStartFallback: Bool = false
    ) -> VoiceProcessingBindResult {
        let boundInputDeviceIDBeforeWrap = inputNode.auAudioUnit.deviceID

        guard enableVoiceProcessing, !suppressedByStartFallback else {
            // Opt-in toggle is off. Be explicit here instead of trusting our
            // cached flag, because a prior route change can leave VPIO armed
            // until the input node is told to release it.
            //
            // Capture the pre-call state `disarmVoiceProcessing` is about to
            // branch on so the returned bind result matches whatever it
            // actually leaves behind — including its own early return when
            // the engine is running, which does NOT clear the cache. See
            // `voiceProcessingEnabledAfterDisarmAttempt`'s doc comment.
            let engineIsRunningBeforeDisarm = engine?.isRunning ?? false
            let voiceProcessingEnabledBeforeDisarm = voiceProcessingEnabled
            disarmVoiceProcessing(
                on: inputNode,
                reason: suppressedByStartFallback ? "start_fallback_non_vpio" : "preference_off"
            )
            return VoiceProcessingBindResult(
                boundInputDeviceIDBeforeWrap: boundInputDeviceIDBeforeWrap,
                enabled: Self.voiceProcessingEnabledAfterDisarmAttempt(
                    engineIsRunning: engineIsRunningBeforeDisarm,
                    priorVoiceProcessingEnabled: voiceProcessingEnabledBeforeDisarm
                )
            )
        }

        if voiceProcessingEnabled, inputNode.isVoiceProcessingEnabled {
            return VoiceProcessingBindResult(
                boundInputDeviceIDBeforeWrap: boundInputDeviceIDBeforeWrap,
                enabled: true
            )
        }

        if let engine, engine.isRunning {
            // VPIO can only be toggled while the engine is stopped. Defer until
            // the next start cycle re-enters this path.
            return VoiceProcessingBindResult(
                boundInputDeviceIDBeforeWrap: boundInputDeviceIDBeforeWrap,
                enabled: voiceProcessingEnabled
            )
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

        return VoiceProcessingBindResult(
            boundInputDeviceIDBeforeWrap: boundInputDeviceIDBeforeWrap,
            enabled: voiceProcessingEnabled
        )
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
        // A fast retry can begin before stop()'s deferred main-thread cleanup.
        // Reset the old timer here so every recording gets a fresh watchdog
        // and buffer timestamp.
        stopWatchdog()
        error = nil
        systemBufferCount = 0  // Reset debug counter (lock-protected)
        micBufferCount = 0
        micAudioStreaming = false  // Re-gate readiness on a fresh first buffer
        systemAudioStreaming = false  // Re-gate readiness on a fresh first buffer
        resetSignalDiagnostics()
        // Fresh instance = clean one-shot latch per recording.
        quietMicAttenuationDetector = QuietMicAttenuationDetector()
        recordingStartRouteVolumeSnapshot = AudioRouteVolumeSnapshot.captureDefaultRoute()
        resetRecordingStartCapturedInput()
        resetSilenceTracking()  // Start fresh silence tracking
        systemAudioStatus = .healthy  // Assume healthy until we hear otherwise
        systemAudioSilenceStart = nil  // Reset system audio silence tracking
        beginRecordingSessionGeneration()
        resetMeetingRouteState()
        recordVoiceProcessingStartFallback(.none)

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
        // Arm even when the graph has not delivered its first mic frame yet.
        // A Bluetooth-to-built-in handoff can pass device/rate validation and
        // `engine.start()` while still producing zero frames. The watchdog's
        // bounded, generation-guarded recovery then gets one chance before the
        // outer meeting-start deadline fails closed.
        if MicWatchdogArmingPolicy.shouldArmAfterSuccessfulStart(
            watchdogIsArmed: watchdogTimer != nil
        ) {
            startWatchdog()
        }
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

    /// Records that the microphone tap delivered a usable buffer for this
    /// recording. Like the system-side latch, this is published on main and
    /// guarded against callbacks that outlive their recording generation.
    func markMicAudioStreamingIfCurrent(sessionGeneration: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recordingSessionGeneration == sessionGeneration else { return }
            self.micAudioStreaming = true
        }
    }

    // MARK: - Stop Recording

    public func stop() {
        // Bump generation synchronously on the calling thread so any
        // concurrent recovery work that checks the generation immediately
        // sees the new session boundary.
        let captureGeneration = recordingSessionGeneration
        pendingStartIntentId = nil
        let stopGeneration = beginRecordingSessionGeneration()

        // Snapshot every reference the teardown will need so the
        // background queue closure isn't reading mutable instance state
        // while UI updates happen in parallel.
        let engineRef = self.engine
        let inputNodeRef = self.inputNode
        let micAudioFileRef = micAudioFileQueue.sync {
            self.micAudioFileOwnership.takeWriterAndInvalidate(for: stopGeneration)
        }
        let systemAudioAttempt = systemAudioFileQueue.sync {
            self.systemAudioCaptureAttemptOwnership.takeAttemptOwned(
                by: captureGeneration
            )
        }
        let systemCaptureAttempt = systemAudioAttempt?.capture
        let systemAudioFileRef = systemAudioAttempt?.writer
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
        retainStoppingJournalSession(journalSession, generation: stopGeneration)
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

            self.withAudioGraphLock {
                guard self.recordingSessionGeneration == stopGeneration else {
                    AppLogger.audio.info("Skipping stale audio graph teardown because a newer session exists", [
                        "stopGeneration": "\(stopGeneration)",
                        "currentGeneration": "\(self.recordingSessionGeneration)"
                    ])
                    return
                }

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

            // The capture reference belongs to this exact attempt. Stop it even
            // when mic-graph teardown is stale; a newer attempt owns a different
            // capture engine and cannot be affected.
            systemCaptureAttempt?.cancel()

            // Coordinate file close. With the engine fully stopped above,
            // no new buffers will arrive on these queues — closing here is
            // safe. If this stop is stale, only clear the file handles that
            // belonged to the stopped generation.
            let cleanupGroup = DispatchGroup()

            cleanupGroup.enter()
            self.micAudioFileQueue.async { [weak self] in
                if let self, let micAudioFileRef {
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
            self.systemAudioFileQueue.async {
                if let systemAudioFileRef {
                    systemAudioFileRef.close()
                    AppLogger.audioSystem.info("Audio file closed", ["file": finalSystemURL?.lastPathComponent ?? "unknown"])
                }
                cleanupGroup.leave()
            }

            cleanupGroup.notify(queue: .global(qos: .utility)) { [weak self] in
                guard let self else { return }
                let micFinalization = self.finalizeStoppedMicRecordingResult(
                    primaryURL: primaryMicURL,
                    segments: micSegmentsSnapshot,
                    generation: stopGeneration
                )
                DispatchQueue.main.async {
                    if self.recordingSessionGeneration == stopGeneration {
                        self.originalMicAudioFileURL = nil
                        self.micSegments = []
                        self.micAudioFileURL = micFinalization.micURL
                    } else {
                        AppLogger.audio.info("Recording completion belongs to stale stop; preserving current capture state", [
                            "stopGeneration": "\(stopGeneration)",
                            "currentGeneration": "\(self.recordingSessionGeneration)"
                        ])
                    }
                    self.onRecordingCompleteWithGeneration?(
                        stopGeneration,
                        micFinalization.micURL,
                        finalSystemURL,
                        micFinalization.disposition
                    )
                    self.onRecordingComplete?(micFinalization.micURL, finalSystemURL)
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
            let monitoringAttempt = SystemAudioCaptureStartAttempt(capture: capture)
            if let displacedAttempt = replaceSystemAudioMonitoringAttempt(with: monitoringAttempt) {
                systemAudioSetupQueue.async {
                    displacedAttempt.cancel()
                }
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try monitoringAttempt.prepare()
                    let started = try monitoringAttempt.startIfNotCancelled { [weak self] systemBuffer in
                        self?.calculateSystemLevel(buffer: systemBuffer)
                    }
                    if started,
                       self?.currentSystemAudioMonitoringAttemptIs(monitoringAttempt) == true {
                        AppLogger.audioSystem.info("System audio monitoring started")
                    }
                } catch {
                    AppLogger.audioSystem.warning("System audio monitoring unavailable", ["error": error.localizedDescription])
                    // Mic monitoring still works — system audio is optional
                }
            }
        }

        isMonitoring = true
    }

    /// Stop level metering. Called automatically before `start()` begins full recording.
    public func stopMonitoring() {
        let monitoringAttempt = replaceSystemAudioMonitoringAttempt(with: nil)
        guard isMonitoring || monitoringAttempt != nil else { return }

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

        if let monitoringAttempt {
            // ScreenCaptureKit start/stop can each wait for a bounded callback.
            // Keep that serialization on the attempt, but never make the UI
            // thread wait while monitoring hands off to full recording.
            systemAudioSetupQueue.async {
                monitoringAttempt.cancel()
            }
        }

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
        systemAudioRecoveryEventCancellable?.cancel()
        replaceSystemAudioMonitoringAttempt(with: nil)?.cancel()
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

extension Audio: AudioCaptureEngine {}

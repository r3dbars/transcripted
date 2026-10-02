import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine
import Synchronization

/// Main audio recording class that captures microphone and system audio
/// Note: This class does NOT use @MainActor because it manages AVAudioEngine
/// which requires synchronous access from audio tap callbacks on audio threads.
/// UI updates are dispatched to main thread explicitly.
/// The mutable audio-capture state is guarded by dedicated queues, locks, and
/// explicit main-thread dispatch where needed, so Dispatch callbacks can safely
/// hold weak references to this object.
public class Audio: ObservableObject, @unchecked Sendable {
    @Published public var isRecording: Bool = false
    var isStarting: Bool = false  // Prevents double-start during async setup
    var pendingStartIntentId: UUID?
    @Published public var audioLevel: Float = 0.0
    @Published public var recordingDuration: TimeInterval = 0.0
    @Published public var audioLevelHistory: [Float] = Array(repeating: 0.0, count: 15)
    @Published public var systemAudioLevelHistory: [Float] = Array(repeating: 0.0, count: 15)
    @Published public var error: String?
    @Published public var systemAudioStatus: SystemAudioStatus = .unknown
    @Published public internal(set) var startFailureStage: AudioCaptureStartFailureStage = .unknown
    /// True only when the current start attempt received ScreenCaptureKit's
    /// typed `userDeclined` error. Kept separate from display copy so a prior
    /// inconclusive preflight cannot soften a later confirmed denial.
    @Published public internal(set) var systemAudioStartPermissionExplicitlyDenied = false

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
    /// System-audio URL set when the WAV is created, not after I/O start
    /// returns. Stop reads this (and ownership / journal) instead of relying
    /// only on the @Published `systemAudioFileURL`, which can still be nil.
    var originalSystemAudioFileURL: URL?
    var _micSegments: [MicRecordingSegment] = []
    let micSegmentsLock = NSLock()
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
    var stoppingRecordingFinalizations: [UInt64: StoppingRecordingFinalization] = [:]
    let stoppingJournalSessionsLock = NSLock()

    // MARK: - Recording Health Tracking (Phase 1: Sleep/Wake + Gap Logging)

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
    /// Thread-safe: reset on main thread; incremented from BOTH the mic-path
    /// background recovery queue and the SCK recovery-event subscription on
    /// main. The get/set pair above is only safe for whole-value resets
    /// (`deviceSwitchCount = 0`) — a `+=`-style increment through it does a
    /// get and a set as two separate lock acquisitions, so two concurrent
    /// incrementers can race and drop an update. `incrementDeviceSwitchCount()`
    /// does the read-modify-write inside ONE lock acquisition; every
    /// increment site must go through it instead of `deviceSwitchCount += 1`.
    var _deviceSwitchCount: Int = 0
    let deviceSwitchCountLock = NSLock()
    var deviceSwitchCount: Int {
        get { deviceSwitchCountLock.lock(); defer { deviceSwitchCountLock.unlock() }; return _deviceSwitchCount }
        set { deviceSwitchCountLock.lock(); defer { deviceSwitchCountLock.unlock() }; _deviceSwitchCount = newValue }
    }

    /// Times this recording rebuilt its mic graph because the input format
    /// moved underneath it (AirPods flipping to their call profile). Shares
    /// the device-switch lock; never touched from the real-time tap.
    var _micFormatRebuildCount: Int = 0
    var micFormatRebuildCount: Int {
        deviceSwitchCountLock.lock(); defer { deviceSwitchCountLock.unlock() }
        return _micFormatRebuildCount
    }

    /// Timestamp when system started sleeping (for gap calculation)
    var sleepTimestamp: Date?

    var engine: AVAudioEngine?
    var inputNode: AVAudioInputNode?
    /// Set instead of `engine`/`inputNode` when the meeting mic records
    /// through `PinnedMicrophoneCapture`. See `Audio+PinnedMicrophone.swift`.
    var pinnedMicrophoneCapture: PinnedMicrophoneCapture? {
        didSet { pinnedMicrophoneRecording.store(pinnedMicrophoneCapture != nil, ordering: .releasing) }
    }
    /// Lock-free mirror of `pinnedMicrophoneCapture != nil` for main-thread
    /// readers; the graph lock can be held across slow HAL calls.
    let pinnedMicrophoneRecording = Atomic<Bool>(false)
    /// Record the meeting mic through a Core Audio IOProc on the selected
    /// device instead of an `AVAudioEngine` input node, which opens the macOS
    /// default input (AirPods) first. Ignored when Apple voice processing is
    /// requested. Set before `start()`; the app reads its rollout preference.
    public var usesPinnedMicrophoneCapture: Bool = false
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

    private let microphoneSharingSuppression = Atomic<Bool>(false)
    let microphoneSharingReconciliationPending = Atomic<Bool>(false)

    /// Host-owned call-app protection, independent of the user's processing
    /// preference. Set before start; a live false -> true transition must also
    /// call reconcileMicrophoneSharing(). Keep it latched until the next start.
    public var voiceProcessingSuppressedForMicrophoneSharing: Bool {
        get { microphoneSharingSuppression.load(ordering: .acquiring) }
        set { microphoneSharingSuppression.store(newValue, ordering: .releasing) }
    }

    var shouldArmVoiceProcessing: Bool {
        enableVoiceProcessing && !voiceProcessingSuppressedForMicrophoneSharing
    }

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
    // Matches the system-audio backend, which also uses CACurrentMediaTime().
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

    /// Last system-audio buffer arrival (monotonic). Used by the post-wake
    /// handler so a healthy stream is not restarted just because the Mac woke.
    private var _lastSystemBufferTime: CFTimeInterval = CACurrentMediaTime()
    private let lastSystemBufferTimeLock = NSLock()
    var lastSystemBufferTime: CFTimeInterval {
        get {
            lastSystemBufferTimeLock.lock()
            defer { lastSystemBufferTimeLock.unlock() }
            return _lastSystemBufferTime
        }
        set {
            lastSystemBufferTimeLock.lock()
            defer { lastSystemBufferTimeLock.unlock() }
            _lastSystemBufferTime = newValue
        }
    }

    /// While held, system-file writes are dropped so a recovery silence pad
    /// can be written first. Not a second PCM queue — writes are discarded.
    ///
    /// A count, not a flag: recoveries can overlap (a reconnect can start
    /// again before the previous one's `.gap` or `.recoveryAbandoned`
    /// arrives), so a successor can arm before the predecessor's release
    /// runs. With a flag that release would drop the
    /// successor's hold and its post-restart buffers would land ahead of
    /// its pad. Each arm is balanced by exactly one release (`.gap` or
    /// `.recoveryAbandoned`), and a new recording resets the count.
    let systemRecoveryWriteHoldLock = NSLock()
    var _systemRecoveryWriteHoldCount = 0
    var watchdogTimer: Timer?
    /// Watches `AVAudioEngineConfigurationChange` so an output or default
    /// device switch restarts the mic right away instead of waiting for the
    /// watchdog. Installed once; see `installMicEngineConfigurationChangeObserver()`.
    var micEngineConfigurationObserver: NSObjectProtocol?

    // Mic recovery ownership (prevents concurrent recovery attempts across
    // recording-session boundaries). The owner stays set until the background
    // recovery actually returns; a fast stop/start cannot clear it from under
    // the older recovery with an unscoped Bool assignment.
    var _micRecoverySessionGeneration: UInt64?
    let micRecoveryLock = NSLock()
    var isMicRecovering: Bool {
        get {
            micRecoveryLock.lock()
            defer { micRecoveryLock.unlock() }
            return _micRecoverySessionGeneration != nil
        }
    }

    // Set from will-sleep until the wake recovery kick. While the Mac is
    // going to sleep the mic stops delivering and the HAL may swap the
    // input, so a watchdog recovery then cannot get a frame back and would
    // end the whole recording. Scoped to the session it was set for, so a
    // stale mark can never hold a later recording's recovery.
    struct SystemSleepMark {
        let sessionGeneration: UInt64
        let markedAt: CFTimeInterval
    }
    var _systemSleepMark: SystemSleepMark?
    // Counts will-sleep notices, so a wake's delayed recovery can tell that
    // the Mac went back to sleep before it ran.
    var _systemSleepSequence: UInt64 = 0
    let systemSleepPendingLock = NSLock()

    var lastRecoveryTime: Date?
    private var _lastRecoveryEndTime: Date?
    private var _micRecoveryGapAnchor: CFTimeInterval?
    private var _recoveryAttemptCount: Int = 0
    private let recoveryAttemptCountLock = NSLock()
    /// When the last mic recovery returned, successful or not. Written by the
    /// recovery thread, read by the route-change check, reset on main.
    var lastRecoveryEndTime: Date? {
        get { recoveryAttemptCountLock.lock(); defer { recoveryAttemptCountLock.unlock() }; return _lastRecoveryEndTime }
        set { recoveryAttemptCountLock.lock(); defer { recoveryAttemptCountLock.unlock() }; _lastRecoveryEndTime = newValue }
    }
    /// Last frame the recording kept before the current failed-recovery
    /// streak closed its segment. Cleared once a recovery succeeds.
    var micRecoveryGapAnchor: CFTimeInterval? {
        get { recoveryAttemptCountLock.lock(); defer { recoveryAttemptCountLock.unlock() }; return _micRecoveryGapAnchor }
        set { recoveryAttemptCountLock.lock(); defer { recoveryAttemptCountLock.unlock() }; _micRecoveryGapAnchor = newValue }
    }
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
    var _meetingInputDeviceSelectionMode: MeetingInputDeviceSelectionMode = .automatic
    var _activeMeetingInputDeviceSelectionMode: MeetingInputDeviceSelectionMode = .automatic
    var _meetingPreferredInputDeviceUID: String?
    var _activeMeetingPreferredInputDeviceUID: String?
    var _lastAttemptedMeetingSelectionReason: MeetingInputDeviceSelectionReason?
    var _meetingInputSelection: MeetingInputDeviceSelection?
    var _meetingRouteStabilizationAttemptCount = 0
    var _meetingRouteStabilizationOutcome: CaptureRouteStabilizationOutcome = .notNeeded
    var _meetingRouteStabilityWarningEmitted = false
    let meetingRouteStateLock = NSLock()

    let recordingLanguageLock = NSLock()
    var requestedRecordingLanguage: TranscriptionLanguageSelection = .automatic
    var activeRecordingLanguage: TranscriptionLanguageSelection = .automatic

    let systemAudioCaptureRequestLock = NSLock()
    var requestedCapturesSystemAudio = true
    var activeRecordingCapturesSystemAudio = true

    // One-shot diagnostics marker for the bounded start-time fallback that
    // retries the meeting mic graph without Apple voice processing after VPIO
    // was requested but did not become active. Separate from
    // `resetMeetingRouteState()` on purpose: the retry loop resets route state
    // mid-build and device recovery resets it mid-session, but this marker
    // must survive until the next `prepareForNewRecordingStart()` so the
    // start-failed/started diagnostics snapshot can report whether the
    // fallback engaged.
    var _voiceProcessingStartFallback: VoiceProcessingStartFallbackState = .none
    let voiceProcessingStartFallbackLock = NSLock()

    // Recording session generation - increments on each start/stop so delayed
    // recovery work from an old session cannot restart a newer one. Mutations
    // stay lock-confined, but reads go through a lock-free atomic mirror
    // (stored inside the same critical sections): the getter is the staleness
    // gate in per-buffer audio callbacks — mic tap, recovery tap, and
    // system-audio — so a lock-free read keeps those callbacks from ever
    // blocking behind a start/stop mid-bump. (The tap thread is not the HAL
    // real-time thread — see calculateLevel — so this is contention hygiene,
    // not a real-time-safety requirement.)
    var recordingSessionGenerationEpoch = SupersessionEpoch()
    let recordingSessionGenerationLock = NSLock()
    private let recordingSessionGenerationMirror = Atomic<UInt64>(0)
    var recordingSessionGeneration: UInt64 {
        get {
            recordingSessionGenerationMirror.load(ordering: .acquiring)
        }
        set {
            recordingSessionGenerationLock.lock()
            defer { recordingSessionGenerationLock.unlock() }
            recordingSessionGenerationEpoch = SupersessionEpoch(testRawValue: newValue)
            recordingSessionGenerationMirror.store(newValue, ordering: .releasing)
        }
    }

    // Test seam: runs on the advancing thread right after the generation
    // moves, outside the lock. Lets a test deliver a buffer at the exact
    // instant a stale one would arrive. Always nil in the app.
    private var _afterRecordingSessionGenerationAdvance: ((UInt64) -> Void)?
    var afterRecordingSessionGenerationAdvanceForTesting: ((UInt64) -> Void)? {
        get {
            recordingSessionGenerationLock.lock()
            defer { recordingSessionGenerationLock.unlock() }
            return _afterRecordingSessionGenerationAdvance
        }
        set {
            recordingSessionGenerationLock.lock()
            defer { recordingSessionGenerationLock.unlock() }
            _afterRecordingSessionGenerationAdvance = newValue
        }
    }

    @discardableResult
    func beginRecordingSessionGeneration() -> UInt64 {
        recordingSessionGenerationLock.lock()
        let generation = recordingSessionGenerationEpoch.begin().rawValue
        recordingSessionGenerationMirror.store(generation, ordering: .releasing)
        let afterAdvance = _afterRecordingSessionGenerationAdvance
        recordingSessionGenerationLock.unlock()
        afterAdvance?(generation)
        return generation
    }

    // Public so callers that need "the generation the NEXT session will get"
    // (e.g. MeetingCaptureBridge's stop-completion gating) ask the epoch
    // instead of hand-predicting with `current &+ 1`, which races with a
    // concurrent begin().
    public func predictedNextRecordingSessionGeneration() -> UInt64 {
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

    // Write errors are generation-scoped. A fast successor can begin while the
    // previous recording's bounded tail is still draining, so an old write must
    // never increment, reset, or trip the successor's failure counter.
    var micWriteErrorsByGeneration: [UInt64: Int] = [:]
    var systemWriteErrorsByGeneration: [UInt64: Int] = [:]
    let writeErrorLock = NSLock()
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
    /// A blocked or slow filesystem must not turn PCM callbacks into an
    /// unlimited collection of retained buffers. Eight MiB per stream is a
    /// hard process-memory ceiling for queued writes, not a target backlog.
    let systemAudioWriteBackpressure = PCMBufferBackpressureGate(byteLimit: 8 * 1_024 * 1_024)
    let micAudioWriteBackpressure = PCMBufferBackpressureGate(byteLimit: 8 * 1_024 * 1_024)
    let micHostPCMBufferFanout = BoundedPCMBufferFanout(
        label: "com.transcripted.meeting-mic-host-fanout",
        byteLimit: 8 * 1_024 * 1_024
    )
    let writeBackpressureStopAdmission = PCMBackpressureStopAdmission()

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
    var _micRawPeak: Float = 0
    var _micProcessedPeak: Float = 0
    var _systemAudioPeak: Float = 0
    var finishingSystemSignalAttempt: SystemAudioCaptureStartAttempt?
    // Interval-scoped mic facts consumed by the 0.2s recording timer for the
    // live issue #500 attenuation detector. Zeroed every drain so one loud
    // cough cannot mask later attenuation the way the lifetime maxima do.
    // `_intervalMinAppliedGain` is nil when no AGC-processed buffer arrived
    // this interval; updated via min so one unpinned buffer disqualifies
    // the tick.
    var _intervalMicRawPeak: Float = 0
    var _intervalMicProcessedPeak: Float = 0
    var _intervalMinAppliedGain: Float?
    var _intervalAGCMaxGain: Float?
    var _intervalSawMicBuffer: Bool = false
    let signalDiagnosticsLock = NSLock()

    // Default route volume at recording start. Used only for diagnostics so
    // we can prove Transcripted observed volume scalars rather than changed
    // them.
    var _recordingStartRouteVolumeSnapshot: AudioRouteVolumeSnapshot?
    let routeVolumeDiagnosticsLock = NSLock()

    // Input volume on the device meetings actually capture from after input
    // selection has run. This can differ from the default input on Bluetooth
    // fallback routes.
    var _recordingStartCapturedInputVolume = "unavailable"
    var _recordingStartCapturedInputDeviceID: AudioDeviceID?

    // System audio status observation
    private var systemAudioCancellable: AnyCancellable?
    // Recovery/health event observation (device-switch + gap parity with the
    // mic path). Separate from `systemAudioCancellable` so re-wiring one
    // subscription on a new capture attempt doesn't need to touch the other.
    private var systemAudioRecoveryEventCancellable: AnyCancellable?
    /// Synchronous subscriber so recovery write-hold is armed on the sending
    /// thread before SCK's async restart can deliver buffers.
    private var systemAudioRecoveryPadCancellable: AnyCancellable?
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
    var sleepObserver: NSObjectProtocol?
    var wakeObserver: NSObjectProtocol?

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

    // Callback for when recording starts (used for pre-loading models)
    public var onRecordingStart: (() -> Void)?

    // Cosmetic capture lifecycle cues. Embedders decide how (or whether) to
    // surface these — typically a UI sound. Fires from whichever queue the
    // underlying lifecycle event runs on; the host should hop to the main
    // actor before touching UI.
    public var onCaptureLifecycleCue: ((CaptureLifecycleCue) -> Void)?

    // MARK: - Shared microphone PCM hook
    //
    // This callback lets an embedder tap mic PCM as it arrives
    // from CoreAudio, in parallel with the WAV file writes. The app uses this
    // to let dictation borrow the active meeting microphone without starting
    // a second audio engine.
    //
    // Threading: fired on the audio thread (same thread as the tap callback).
    // Consumers MUST NOT do I/O or blocking work on this thread — hand the
    // owned buffer to a bounded worker. Matching the convention of
    // `onRecordingComplete`, optional reads are unsynchronized: set the hook
    // once before `start()` and do not reassign during recording.
    //
    // Mic buffers are the same processed copy that is written to the saved mic
    // WAV: software AGC when VPIO is off, or Apple's VPIO output when VPIO is
    // on. The callback receives that owned processed copy.
    public var onMicPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Filesystem layout used for writing raw mic/system WAV captures.
    /// Embedders can redirect captures by passing a custom `CoreStoragePaths` at init.
    let paths: CoreStoragePaths
    let sleepWakeNotifications: AudioSleepWakeNotifications

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
        self.systemAudioCaptureFactory = { CoreAudioSystemAudioCapture() }
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
        installMicEngineConfigurationChangeObserver()
        guard systemAudioCapture == nil else { return }

        // Core Audio process taps capture system audio without enumerating
        // screens or requiring the broader screen-recording permission.
        guard let capture = systemAudioCaptureFactory() else { return }
        systemAudioCapture = capture
        wireSystemAudioStatusPublisher(from: capture)
        installWorkspaceSleepWakeObservers()
    }

    /// Builds this recording's system-audio tap. A mic-only recording never
    /// builds one: that would ask macOS for System Audio Recording and record
    /// silence the user already said they don't want.
    func makeSystemAudioCaptureForRecordingAttempt()
        -> (any SystemAudioCaptureEngine & Sendable)? {
        guard currentRecordingCapturesSystemAudio else {
            AppLogger.audioSystem.info("System audio capture skipped for a mic-only recording", [
                "event": "system_audio_capture_skipped_mic_only"
            ])
            return nil
        }
        guard let capture = systemAudioCaptureFactory() else { return nil }
        systemAudioCapture = capture
        wireSystemAudioStatusPublisher(from: capture)
        return capture
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
                case .systemWake, .fellBehind:
                    // Sleeping the Mac or falling behind is not a route
                    // change. The reconnect's gap is still recorded when its
                    // first buffer lands.
                    break
                case .gap(let duration):
                    // The pad and the hold release already ran on the
                    // sending thread; see `padSystemAudioGapBeforeNextBuffer`.
                    self.appendSystemAudioGap(duration: duration)
                case .recoveryAbandoned:
                    break
                }
            }
        // Arm the write-hold on the sending thread so it is visible before
        // SCK start() can deliver the first post-restart buffer, and release
        // it on the same thread when the recovery ends, with or without a
        // `.gap`, so the first buffer after the pad is written.
        systemAudioRecoveryPadCancellable = capture.recoveryEventPublisher
            .sink { [weak self] event in
                switch event {
                case .deviceSwitch, .systemWake, .fellBehind:
                    self?.armSystemRecoveryWriteHold()
                case .recoveryAbandoned:
                    self?.releaseSystemRecoveryWriteHold()
                case .gap(let duration):
                    self?.padSystemAudioGapBeforeNextBuffer(duration: duration)
                }
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
        if let observer = micEngineConfigurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        timer?.invalidate()
        watchdogTimer?.invalidate()
        systemAudioCancellable?.cancel()
        systemAudioRecoveryEventCancellable?.cancel()
        systemAudioRecoveryPadCancellable?.cancel()
        systemAudioCapture?.stopSync()
        pinnedMicrophoneCapture?.stop()

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

// Support/TranscriptedConstants.swift
// Centralized configuration constants — timeouts, thresholds, limits, buffer sizes.
// Animation durations and UI dimensions stay in their respective files (OverlayTokens, etc.)

import Foundation

enum TranscriptedConstants {

    // MARK: - Versioning

    static let appPipelineVersion = 2

    // MARK: - Audio & Speech

    /// Max duration for a dictation listening session before the auto-save cap
    /// fires. Shared by the session timeout and audio buffer sizing so the two
    /// cannot drift apart.
    static let dictationSessionMaxDuration: TimeInterval = 5 * 60

    /// Audio buffer capacity in seconds — the dictation session cap plus
    /// headroom for the stop path, so the cap never truncates audio without
    /// reserving a half-hour worst case (~345MB of Float samples at 48kHz)
    /// that persists for the process lifetime.
    static let audioBufferCapacitySeconds = Int(dictationSessionMaxDuration) + 60

    /// Audio tap buffer size (AVAudioEngine installTap)
    static let audioTapBufferSize: UInt32 = 1024

    /// Audio level metering throttle interval in seconds (~20Hz)
    static let audioMeteringInterval: TimeInterval = 0.05

    /// Audio level floor in dB (below this = silence)
    static let audioLevelFloorDB: Float = -50.0

    /// Audio level ceiling in dB (above this = max)
    static let audioLevelCeilingDB: Float = -6.0

    /// Target sample rate for Parakeet inference
    static let parakeetSampleRate: Double = 16000.0

    /// Minimum audio duration required by Parakeet for stable batch inference.
    static let parakeetMinimumAudioDuration: TimeInterval = 1.0

    /// Minimum sample count required by Parakeet at the target sample rate.
    static let parakeetMinimumInferenceSamples = Int(parakeetSampleRate * parakeetMinimumAudioDuration)

    static func hasMinimumParakeetAudioSamples(_ sampleCount: Int) -> Bool {
        sampleCount >= parakeetMinimumInferenceSamples
    }

    /// Delay for audio input readiness retry after device change (nanoseconds)
    static let audioRecoveryDelay: UInt64 = 300_000_000  // 300ms

    /// Window (seconds) during which Parakeet ignores its own config-change
    /// notifications after intentionally touching the input graph (applying
    /// the built-in-mic override, or resetting a zombie engine). Bluetooth
    /// route renegotiation after that kind of touch commonly takes longer
    /// than 1s, so this must outlast typical AirPods HFP/A2DP settling —
    /// otherwise the self-induced notification re-enters the device-change
    /// handler and triggers an unnecessary rebuild.
    static let selfInducedConfigChangeIgnoreWindow: TimeInterval = 2.5

    /// Rolling window (seconds) used to detect a rebuild-churn loop — repeated
    /// full audio-engine rebuilds in quick succession, which on Bluetooth routes
    /// audibly disrupts other apps' playback each time. This should never fire
    /// under normal device-change recovery; it exists as a guardrail so a
    /// regression here shows up in telemetry instead of only as "my music keeps
    /// cutting out."
    static let audioEngineRebuildChurnWindow: TimeInterval = 10.0

    /// Rebuild count within `audioEngineRebuildChurnWindow` that counts as churn.
    static let audioEngineRebuildChurnThreshold: Int = 5

    /// Watchdog timeout — if no audio samples arrive within this window after starting
    /// recording, the engine is likely a zombie (running but disconnected from hardware)
    static let audioWatchdogTimeout: UInt64 = 2_000_000_000  // 2 seconds

    /// Timeout for MeetingCaptureBridge.startRecording — resolves the start
    /// continuation with the current `isRecording` state after this window if
    /// neither the success nor error publisher has fired.
    static let meetingStartTimeout: UInt64 = 5_000_000_000  // 5 seconds

    /// Base timeout for waiting on meeting capture file-close callbacks after
    /// stop. Long recordings can need more time to flush and merge audio, so
    /// call `meetingStopTimeout(forRecordingDuration:)` for live capture.
    static let meetingStopTimeout: UInt64 = 30_000_000_000  // 30 seconds

    /// Maximum stop wait for long recordings. This keeps 2h+ meetings from
    /// being failed while audio finalization is still making progress.
    static let meetingMaximumStopTimeout: UInt64 = 120_000_000_000  // 120 seconds

    /// Adds this much stop-wait budget for each recorded hour, capped by
    /// `meetingMaximumStopTimeout`.
    static let meetingStopTimeoutGrowthStep: UInt64 = 30_000_000_000  // 30 seconds

    static func meetingStopTimeout(forRecordingDuration duration: TimeInterval) -> UInt64 {
        guard duration.isFinite, duration >= 3_600 else { return meetingStopTimeout }

        let maxGrowthSteps = (meetingMaximumStopTimeout - meetingStopTimeout) / meetingStopTimeoutGrowthStep
        let recordedHours = UInt64(min(ceil(duration / 3_600), Double(maxGrowthSteps)))
        guard recordedHours > 0 else { return meetingStopTimeout }

        let scaledTimeout = meetingStopTimeout + (recordedHours * meetingStopTimeoutGrowthStep)
        return min(scaledTimeout, meetingMaximumStopTimeout)
    }

    /// Max time app termination waits for an in-flight meeting stop to finish.
    /// This must stay above the maximum scaled stop timeout so quit
    /// preservation does not give up before the bridge returns retained audio
    /// URLs.
    static let meetingTerminationFinishWaitTimeout: TimeInterval = 125.0

    /// Failed meeting audio is recoverable, but old unretried files should not grow forever.
    static let failedMeetingAudioRetentionDays = 30

    /// Max time wake recovery should wait for background model warmup.
    /// Hotkey recovery must finish even if a model load stalls after sleep.
    static let wakeRuntimeReadinessTimeout: TimeInterval = 30.0

    /// Debounce window for coalescing rapid audio config change notifications (e.g. BT reconnect bursts)
    static let audioConfigChangeDebounceDelay: UInt64 = 250_000_000  // 250ms

    /// Max time a device-change recovery may stay active before being marked
    /// failed. This leaves room inside `dictationRecoveryBudget` for a fallback
    /// prewarm/start attempt.
    static let audioDeviceRecoveryTimeout: UInt64 = 4_000_000_000  // 4 seconds

    /// Max time a single CoreAudio startup operation may sit on the audio-engine
    /// worker before Transcripted treats the graph as blocked and rebuilds it.
    static let audioStartOperationTimeout: UInt64 = 1_500_000_000  // 1.5 seconds

    /// Total budget for dictation to wait on engine readiness after a device change.
    /// Sized to cover slower USB/Bluetooth CoreAudio graph rebuilds without trapping
    /// users indefinitely; the overlay remains cancellable during this window.
    static let dictationRecoveryBudget: TimeInterval = 6.0

    /// Poll interval while dictation waits on engine readiness (nanoseconds).
    static let dictationReadinessPollInterval: UInt64 = 100_000_000  // 100ms

    /// Minimum interval between active readiness refreshes while dictation waits.
    /// This lets a failed recovery get unstuck without hammering CoreAudio.
    static let dictationReadinessRefreshInterval: TimeInterval = 0.3

    /// Max time a single user-started input-readiness refresh may block the
    /// dictation wait loop before it is treated as stale.
    static let dictationReadinessRefreshTimeout: TimeInterval = 0.9

    /// Number of active readiness refreshes before a user-started dictation
    /// performs a hard idle audio graph rebuild.
    static let dictationReadinessForcedRecoveryRefreshes: Int = 5

    /// Max hard recovery attempts inside one user-started dictation wait.
    static let dictationReadinessForcedRecoveryAttempts: Int = 2

    /// Max consecutive prewarm retries before giving up. Each retry waits
    /// `audioRecoveryDelay` (300ms), so 18 retries = ~5.4s of background settling.
    /// Prevents infinite Task chains when the mic is permanently unavailable.
    static let prewarmRetryBudget: Int = 18

    /// Max attempts to restart recording after a device change. Each attempt waits
    /// `recordingRestartRetryDelay` (500ms) to give Bluetooth format negotiation time to settle.
    static let recordingRestartAttempts: Int = 4

    /// Delay between recording-restart attempts after a device change (nanoseconds).
    /// BT format negotiation can take ~1-2s; 500ms between attempts covers most cases.
    static let recordingRestartRetryDelay: UInt64 = 500_000_000  // 500ms

    /// Max immediate retries after AVAudioEngine fails to start for dictation.
    /// Keep this small: the caller already has a readiness wait loop, and repeated
    /// immediate attempts can spam Sentry while CoreAudio is still settling.
    static let audioStartRecoveryAttempts: Int = 1

    /// Minimum interval between Sentry reports for repeated audio-start failures.
    /// Local logs still record each failure; off-device reports stay bounded.
    static let audioStartFailureReportThrottle: TimeInterval = 15.0

    // MARK: - Model Loading

    /// Polling interval while waiting for voice model to load (nanoseconds)
    static let modelLoadPollInterval: UInt64 = 200_000_000  // 200ms

    /// Max polling iterations for model load (600 * 200ms = 120s timeout)
    static let modelLoadMaxIterations = 600

    /// Total time budget for waiting on a voice-model load. Derived from the
    /// poll parameters so joined (non-polling) waits keep the same ceiling.
    static let modelLoadWaitBudget: TimeInterval =
        Double(modelLoadMaxIterations) * Double(modelLoadPollInterval) / 1_000_000_000

    // MARK: - Clipboard

    /// Delay after the target app reads the borrowed dictation text before
    /// restoring the user's clipboard.
    static let clipboardRestoreDelay: UInt64 = 120_000_000  // 120ms

    /// Maximum time to keep borrowed dictation text available if the target app
    /// has not requested it yet. This protects slower paste consumers without
    /// leaving the user's clipboard borrowed indefinitely.
    static let clipboardRestoreFallbackDelay: UInt64 = 2_500_000_000  // 2.5s

    /// Max time to wait for a just-activated target app before paste-back falls
    /// back to copying. This covers menu/settings flows where activation is async.
    static let clipboardTargetActivationWait: TimeInterval = 0.35

    /// Max time to wait for the target app to request the borrowed clipboard
    /// string before treating paste-back as unconfirmed.
    static let clipboardPasteConfirmationWait: TimeInterval = 0.35

    /// Maximum eager data copied per pasteboard type when snapshotting the
    /// user's clipboard before paste-back. Larger/heavy representations are
    /// skipped so stop-to-paste stays responsive.
    static let clipboardSnapshotMaxTypeBytes: Int = 2 * 1024 * 1024

    // MARK: - Dictation Auto Enter

    /// Small pause after paste-back before optionally pressing Enter.
    static let dictationAutoEnterDelay: UInt64 = 150_000_000  // 150ms

    /// Ignore extremely short sessions so quick accidental taps do not submit.
    static let dictationAutoEnterMinimumDuration: TimeInterval = 0.3

    // MARK: - Debug Logging

    /// Debug log rotation threshold in bytes
    static let logRotationThreshold: UInt64 = 500_000  // 500 KB

    /// Max lines to keep when rotating the debug log
    static let logRotationKeepLines = 1000

    /// Throttled logging minimum interval
    static let logThrottleInterval: TimeInterval = 0.25

    /// Size cap for append-only JSONL observability logs (events.jsonl,
    /// reliability.jsonl). On rotation the file is renamed to `<name>.1`,
    /// bounding disk use at roughly twice this value per log.
    static let jsonlLogRotationThreshold: UInt64 = 10_000_000  // 10 MB

    // MARK: - Error Display

    /// Duration to show error messages in overlay before auto-dismiss (nanoseconds)
    static let errorDismissDelay: UInt64 = 2_500_000_000  // 2.5 seconds
    static let noSpeechDismissDelay: UInt64 = 2_200_000_000  // 2.2 seconds — enough time to read the physical-key recovery hint
    /// Clipboard-fallback notices carry a "press ⌘V" instruction, so they dwell
    /// longer than plain errors before fading out.
    static let clipboardNoticeDismissDelay: UInt64 = 4_500_000_000  // 4.5 seconds

    // MARK: - Feedback Sounds

    /// Output volume for short overlay confirmation cues
    static let overlayCueVolume: Float = 0.7
    static let deliveredCueVolumeMultiplier: Float = 0.3

    /// Bundled filenames for app feedback cues (stored in Resources/Sounds/)
    static let listeningStartSoundFileName = "dictation-start.mp3"
    static let dictationDeliveredSoundFileName = "dictation-delivered.m4a"
    static let meetingTranscriptCompleteSoundFileName = "meeting-transcript-complete.mp3"

    // MARK: - Hotkeys

    /// Minimum interval between accepted hotkey actions.
    /// Prevents rapid repeat presses from racing session state transitions.
    static let hotkeyActionDebounceInterval: TimeInterval = 0.2

    // MARK: - Async Utilities

    /// Run an async operation with a deadline. Throws CancellationError on timeout.
    static func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            guard let result = try await group.next() else {
                group.cancelAll()
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }
}

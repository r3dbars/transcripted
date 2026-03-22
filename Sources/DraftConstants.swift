// Draft by Red Bar — Constants
// DraftConstants.swift
// Centralized configuration constants — timeouts, thresholds, limits, buffer sizes.
// Animation durations and UI dimensions stay in their respective files (OverlayTokens, etc.)

import Foundation

enum DraftConstants {

    // MARK: - Versioning

    static let appPipelineVersion = 2

    // MARK: - Generation

    /// Default max tokens for draft responses
    static let draftMaxTokens = 1024

    /// Max tokens for analysis calls
    static let analysisMaxTokens = 2048

    // MARK: - Audio & Speech

    /// Audio buffer pre-allocation capacity in seconds
    static let audioBufferCapacitySeconds = 120

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

    /// Delay for audio engine re-warm after device change (nanoseconds)
    static let audioRecoveryDelay: UInt64 = 300_000_000  // 300ms

    /// Delay for audio engine re-warm after system wake (nanoseconds)
    /// Increased from 500ms to 1s — CoreAudio needs time to fully reinitialize after sleep
    static let audioRewarmDelay: UInt64 = 1_000_000_000  // 1 second

    /// Watchdog timeout — if no audio samples arrive within this window after starting
    /// recording, the engine is likely a zombie (running but disconnected from hardware)
    static let audioWatchdogTimeout: UInt64 = 2_000_000_000  // 2 seconds

    // MARK: - Model Loading

    /// Polling interval while waiting for voice model to load (nanoseconds)
    static let modelLoadPollInterval: UInt64 = 200_000_000  // 200ms

    /// Max polling iterations for model load (600 * 200ms = 120s timeout)
    static let modelLoadMaxIterations = 600

    // MARK: - Clipboard

    /// Clipboard restore polling interval (nanoseconds)
    static let clipboardPollInterval: UInt64 = 50_000_000  // 50ms

    /// Clipboard restore timeout in seconds
    static let clipboardRestoreTimeout: Double = 2.0

    // MARK: - Style & Refinement

    /// Edit distance threshold — below this, profile is "working well" (refine less often)
    static let editDistanceStabilizedThreshold: Double = 0.25

    /// Number of recent examples to send for style refinement
    static let refinementExampleWindow = 20

    /// Number of recent edit distances to check for stabilization
    static let refinementDistanceWindow = 10

    // MARK: - Analysis Engine

    /// Debounce window for feedback file watcher (seconds)
    static let analysisDebounceSeconds: Double = 30.0

    /// Minimum feedback entries before triggering analysis
    static let analysisMinFeedbackEntries = 5

    // MARK: - Data Limits

    /// Recent feedback lines for analysis engine
    static let analysisFeedbackLines = 50

    /// Recent suggestion lines for analysis engine
    static let analysisSuggestionLines = 20

    // MARK: - Debug Logging

    /// Debug log rotation threshold in bytes
    static let logRotationThreshold: UInt64 = 500_000  // 500 KB

    /// Max lines to keep when rotating the debug log
    static let logRotationKeepLines = 1000

    /// Throttled logging minimum interval
    static let logThrottleInterval: TimeInterval = 0.25

    // MARK: - Error Display

    /// Duration to show error messages in overlay before auto-dismiss (nanoseconds)
    static let errorDismissDelay: UInt64 = 2_500_000_000  // 2.5 seconds

    // MARK: - Local Inference

    /// Max tokens for local style refinement
    static let localRefinementMaxTokens = 2048

    /// Max tokens for local bulk analysis during onboarding
    static let localBulkAnalysisMaxTokens = 2048

    /// OCR text truncation limit (total characters kept from screenshot)
    static let ocrMaxCharacters = 3000

    /// OCR header prefix to keep (app chrome, contact name)
    static let ocrHeaderCharacters = 500

    /// OCR recent suffix to keep (latest messages)
    static let ocrRecentCharacters = 2500

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

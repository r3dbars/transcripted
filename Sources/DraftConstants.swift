// DraftConstants.swift
// Centralized configuration constants — timeouts, thresholds, limits, buffer sizes.
// Animation durations and UI dimensions stay in their respective files (OverlayTokens, etc.)

import Foundation

enum DraftConstants {

    // MARK: - API & Network

    /// Delay between retry attempts for transient API errors (nanoseconds)
    static let apiRetryDelay: UInt64 = 2_000_000_000  // 2 seconds

    /// Default max tokens for draft responses
    static let draftMaxTokens = 1024

    /// Max tokens for vision context extraction
    static let visionMaxTokens = 2048

    /// Max tokens for streaming chat responses
    static let chatMaxTokens = 2048

    /// Max tokens for Sonnet analysis/refinement calls
    static let analysisMaxTokens = 4096

    /// Vision extraction timeout (typical calls take 2-6s; 4s was too tight)
    static let visionTimeoutSeconds: Double = 8.0

    /// HTTP request timeout for Sonnet analysis calls
    static let analysisHTTPTimeoutSeconds: Double = 60.0

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

    /// Max live speech restarts within the rate-limit window
    static let liveSpeechMaxRestarts = 5

    /// Live speech restart rate-limit window in seconds
    static let liveSpeechRestartWindowSeconds: TimeInterval = 10.0

    /// Delay for audio engine re-warm after system wake (nanoseconds)
    static let audioRewarmDelay: UInt64 = 500_000_000  // 500ms

    // MARK: - Clipboard

    /// Clipboard restore polling interval (nanoseconds)
    static let clipboardPollInterval: UInt64 = 50_000_000  // 50ms

    /// Clipboard restore timeout in seconds
    static let clipboardRestoreTimeout: Double = 2.0

    // MARK: - Style & Refinement

    /// Edit distance threshold — below this, profile is "working well" (refine less often)
    static let editDistanceStabilizedThreshold: Double = 0.25

    /// Number of recent examples to send for Sonnet refinement
    static let refinementExampleWindow = 20

    /// Number of recent edit distances to check for stabilization
    static let refinementDistanceWindow = 10

    // MARK: - Analysis Engine

    /// Debounce window for feedback file watcher (seconds)
    static let analysisDebounceSeconds: Double = 30.0

    /// Minimum feedback entries before triggering analysis
    static let analysisMinFeedbackEntries = 5

    /// Max tool use turns in multi-turn analysis
    static let analysisMaxToolTurns = 3

    // MARK: - Data Limits

    /// Default max messages to read from iMessage database
    static let imessageDefaultLimit = 2000

    /// Max messages to format for analysis during onboarding
    static let imessageAnalysisLimit = 500

    /// Recent feedback log lines injected into chat context
    static let chatFeedbackContextLines = 25

    /// Recent suggestion log lines injected into chat context
    static let chatSuggestionContextLines = 10

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
    static let errorDismissDelay: UInt64 = 1_500_000_000  // 1.5 seconds
}

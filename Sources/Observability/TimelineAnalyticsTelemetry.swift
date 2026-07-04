import Foundation

/// Central timeline analytics helper.
///
/// Timeline capture can observe screen-derived state, so keep future callers on
/// these coarse enums and buckets. Do not add OCR text, screenshot paths, app
/// names, window titles, URLs, bundle IDs, or personal identifiers here.
enum TimelineAnalyticsTelemetry {
    enum Surface: String {
        case onboarding
        case settings
        case timelineHome = "timeline_home"
        case timelineCapture = "timeline_capture"
        case timelineCard = "timeline_card"
        case timelineMarkdown = "timeline_markdown"
        case menuBar = "menu_bar"
    }

    enum Result: String {
        case success
        case denied
        case failed
        case skipped
        case resumed
        case paused
    }

    enum ProviderKind: String {
        case local
        case localLLM = "local_llm"
        case system
        case none
        case unknown
    }

    enum PermissionState: String {
        case ready
        case denied
        case notDetermined = "not_determined"
        case restricted
        case unknown
    }

    enum PauseReason: String {
        case user
        case permissionDenied = "permission_denied"
        case storageLimit = "storage_limit"
        case idle
        case error
        case unknown
    }

    enum CardKind: String {
        case activity
        case focus
        case meeting
        case dictation
        case summary
        case unknown
    }

    static func trackEnabled(
        surface: Surface,
        result: Result,
        providerKind: ProviderKind,
        permissionState: PermissionState
    ) {
        AnalyticsReporter.track(
            "timeline_enabled",
            properties: [
                "surface": surface.rawValue,
                "result": result.rawValue,
                "provider_kind": providerKind.rawValue,
                "permission_state": permissionState.rawValue,
            ]
        )
    }

    static func trackScreenPermissionReady(
        surface: Surface,
        permissionState: PermissionState = .ready
    ) {
        AnalyticsReporter.track(
            "timeline_screen_permission_ready",
            properties: permissionProperties(
                surface: surface,
                result: .success,
                permissionState: permissionState
            )
        )
    }

    static func trackScreenPermissionDenied(
        surface: Surface,
        permissionState: PermissionState = .denied
    ) {
        AnalyticsReporter.track(
            "timeline_screen_permission_denied",
            properties: permissionProperties(
                surface: surface,
                result: .denied,
                permissionState: permissionState
            )
        )
    }

    static func trackCapturePaused(
        surface: Surface,
        pauseReason: PauseReason
    ) {
        AnalyticsReporter.track(
            "timeline_capture_paused",
            properties: pauseProperties(surface: surface, result: .paused, pauseReason: pauseReason)
        )
    }

    static func trackCaptureResumed(
        surface: Surface,
        pauseReason: PauseReason
    ) {
        AnalyticsReporter.track(
            "timeline_capture_resumed",
            properties: pauseProperties(surface: surface, result: .resumed, pauseReason: pauseReason)
        )
    }

    static func trackCardGenerated(
        surface: Surface,
        cardKind: CardKind,
        providerKind: ProviderKind,
        durationSeconds: Double,
        sourceCount: Int,
        result: Result = .success
    ) {
        AnalyticsReporter.track(
            "timeline_card_generated",
            properties: [
                "surface": surface.rawValue,
                "result": result.rawValue,
                "provider_kind": providerKind.rawValue,
                "card_kind": cardKind.rawValue,
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: durationSeconds),
                "count_bucket": AnalyticsReporter.countBucket(sourceCount),
            ]
        )
    }

    static func trackCardOpened(
        surface: Surface,
        cardKind: CardKind,
        result: Result = .success
    ) {
        AnalyticsReporter.track(
            "timeline_card_opened",
            properties: [
                "surface": surface.rawValue,
                "result": result.rawValue,
                "card_kind": cardKind.rawValue,
            ]
        )
    }

    static func trackDailyMarkdownWritten(
        surface: Surface,
        durationSeconds: Double,
        cardCount: Int,
        result: Result = .success
    ) {
        AnalyticsReporter.track(
            "timeline_daily_markdown_written",
            properties: [
                "surface": surface.rawValue,
                "result": result.rawValue,
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: durationSeconds),
                "count_bucket": AnalyticsReporter.countBucket(cardCount),
            ]
        )
    }

    static func trackUsedAgain(
        surface: Surface,
        returnWindowBucket: String
    ) {
        AnalyticsReporter.track(
            "timeline_used_again",
            properties: [
                "surface": surface.rawValue,
                "return_window_bucket": returnWindowBucket,
            ]
        )
    }

    static func returnWindowBucket(since lastUsedAt: Date?, now: Date = Date()) -> String? {
        guard let lastUsedAt else { return nil }
        let hours = now.timeIntervalSince(lastUsedAt) / 3_600
        switch hours {
        case ..<6:
            return nil
        case ..<18:
            return "6_18h"
        case ..<36:
            return "18_36h"
        case ..<72:
            return "36_72h"
        case ..<168:
            return "3_7d"
        default:
            return "7d_plus"
        }
    }

    static func permissionProperties(
        surface: Surface,
        result: Result,
        permissionState: PermissionState
    ) -> [String: String] {
        [
            "surface": surface.rawValue,
            "result": result.rawValue,
            "permission_state": permissionState.rawValue,
        ]
    }

    static func pauseProperties(
        surface: Surface,
        result: Result,
        pauseReason: PauseReason
    ) -> [String: String] {
        [
            "surface": surface.rawValue,
            "result": result.rawValue,
            "pause_reason": pauseReason.rawValue,
        ]
    }
}

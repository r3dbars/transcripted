import Foundation

/// Content-free outcomes. No saved-result IDs or file-derived values cross this boundary.
enum ProductUsageTelemetry {
    enum Destination: String, CaseIterable {
        case today, meetings, dictations, writing, settings, speakers, agent, unknown
    }

    enum NavigationSource: String, CaseIterable {
        case sidebar, settingsAction = "settings_action", menuBar = "menu_bar"
        case menuCommand = "menu_command", appMenu = "app_menu", dockIcon = "dock_icon"
        case singleInstanceReopen = "single_instance_reopen", meetingOverlay = "meeting_overlay"
        case appLaunch = "app_launch", unknown

        var initiation: String {
            switch self {
            case .appLaunch: return "automatic"
            case .unknown: return "unknown"
            default: return "user"
            }
        }
    }

    enum ArtifactKind: String { case dictation, meeting }
    enum Action: String { case copy, preview, openMarkdown = "open_markdown" }
    enum Surface: String { case dictations, meetings, rowMenu = "row_menu" }

    static func navigationProperties(
        destination: Destination, previous: Destination, source: NavigationSource
    ) -> [String: String] {
        ["destination": destination.rawValue, "previous_destination": previous.rawValue,
         "source": source.rawValue, "initiation": source.initiation]
    }

    static func trackNavigation(destination: Destination, previous: Destination, source: NavigationSource) {
        AnalyticsReporter.track("product_navigation", properties: navigationProperties(
            destination: destination, previous: previous, source: source
        ))
    }

    static func resultProperties(
        kind: ArtifactKind, action: Action, surface: Surface, succeeded: Bool,
        artifactDate: Date?, now: Date = Date()
    ) -> [String: String] {
        ["artifact_kind": kind.rawValue, "action_kind": action.rawValue,
         "surface": surface.rawValue, "result": succeeded ? "success" : "failed",
         "artifact_age_bucket": ActivationTelemetry.artifactAgeBucket(since: artifactDate, now: now)]
    }

    static func trackResult(
        kind: ArtifactKind, action: Action, surface: Surface, succeeded: Bool, artifactDate: Date?
    ) {
        AnalyticsReporter.track("saved_result_action", properties: resultProperties(
            kind: kind, action: action, surface: surface, succeeded: succeeded, artifactDate: artifactDate
        ))
    }

    /// Runs the actual clipboard write before recording its terminal result.
    /// The injected sink keeps the success/failure contract testable without the system clipboard.
    @discardableResult
    static func copy(
        kind: ArtifactKind, surface: Surface, artifactDate: Date?, write: () -> Bool,
        emit: ([String: String]) -> Void = { AnalyticsReporter.track("saved_result_action", properties: $0) }
    ) -> Bool {
        let succeeded = write()
        emit(resultProperties(kind: kind, action: .copy, surface: surface,
                              succeeded: succeeded, artifactDate: artifactDate))
        return succeeded
    }
}

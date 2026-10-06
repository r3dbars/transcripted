import Foundation
import Observation

@Observable
@MainActor
final class TranscriptedSettingsNavigationModel {
    var selectedPage: TranscriptedSettingsPage
    var presentedPage: TranscriptedSettingsPage
    var presentationSource: String
    var presentationID = UUID()
    /// True from `present()` until the window closes (not minimized or hidden).
    /// Work done for a window nobody can see is gated on it.
    var isWindowOpen = false
    /// When `present()` last ran. The app activation it causes would only
    /// repeat reads the presentation's full refresh already does.
    @ObservationIgnored var lastPresentedAt: Date?

    /// Bumped by ⌘F (Find Meetings). Home reveals and focuses its find bar
    /// via `.task(id:)` on this token, which also fires on mount — so the
    /// request survives navigating to Home from another page (a plain
    /// notification would be posted before Home's subscriber exists).
    var homeFindFocusToken = 0

    func requestHomeFindFocus() {
        homeFindFocusToken += 1
    }

    /// Bumped by the Notch island meeting's Open (and Home's own Open on a just-saved
    /// transcript). Home expands the meeting at `homeRevealMeetingURL` once
    /// it appears in the list, using the same mount-safe `.task(id:)` pattern
    /// as the find token.
    var homeRevealMeetingToken = 0
    private(set) var homeRevealMeetingURL: URL?

    func requestHomeRevealMeeting(transcriptURL: URL) {
        homeRevealMeetingURL = transcriptURL
        homeRevealMeetingToken += 1
    }

    /// Call from a control or window presentation with its known source, never from render callbacks.
    func select(_ page: TranscriptedSettingsPage, source: ProductUsageTelemetry.NavigationSource) {
        ProductUsageTelemetry.trackNavigation(
            destination: page.telemetryDestination, previous: selectedPage.telemetryDestination, source: source
        )
        selectedPage = page
    }

    init(selectedPage: TranscriptedSettingsPage = .today) {
        self.selectedPage = selectedPage
        self.presentedPage = selectedPage
        self.presentationSource = "unknown"
    }
}

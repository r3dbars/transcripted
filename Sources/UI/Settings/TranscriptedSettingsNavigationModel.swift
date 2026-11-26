import Foundation
import Observation

@Observable
@MainActor
final class TranscriptedSettingsNavigationModel {
    typealias PageViewSink = @MainActor (TranscriptedSettingsPage, String) -> Void
    typealias NavigationSink = @MainActor (
        ProductUsageTelemetry.Destination,
        ProductUsageTelemetry.Destination,
        ProductUsageTelemetry.NavigationSource
    ) -> Void

    private let pageViewSink: PageViewSink
    private let navigationSink: NavigationSink
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
    /// Told after every `select`, so hang reports can name the open page.
    @ObservationIgnored var onSelect: (() -> Void)?

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

    /// Bumped by Today's dictation clicks. The shell waits for the entry
    /// with this id to load on Dictations, then scrolls to it (mount-safe
    /// `.task(id:)`, like the meeting reveal).
    var dictationRevealToken = 0
    private(set) var dictationRevealEntryID: String?

    func requestDictationReveal(entryID: String) {
        dictationRevealEntryID = entryID
        dictationRevealToken += 1
    }

    /// Call from a control or window presentation with its known source, never from render callbacks.
    /// A retired page (`.files`) lands on the page that replaced it.
    func select(_ requested: TranscriptedSettingsPage, source: ProductUsageTelemetry.NavigationSource) {
        let page = requested.redirected
        let previous = selectedPage
        updateSelection(page, source: source)
        if previous != page {
            pageViewSink(page, "navigation")
        }
    }

    /// One explicit window presentation owns one page view, regardless of render callbacks.
    func present(page requested: TranscriptedSettingsPage, source: String, beforePageView: () -> Void = {}) {
        let page = requested.redirected
        presentedPage = page
        updateSelection(page, source: ProductUsageTelemetry.NavigationSource(rawValue: source) ?? .unknown)
        presentationSource = source
        presentationID = UUID()
        beforePageView()
        pageViewSink(page, source)
    }

    private func updateSelection(_ page: TranscriptedSettingsPage, source: ProductUsageTelemetry.NavigationSource) {
        navigationSink(page.telemetryDestination, selectedPage.telemetryDestination, source)
        selectedPage = page
        onSelect?()
    }

    init(
        selectedPage: TranscriptedSettingsPage = .home,
        pageViewSink: @escaping PageViewSink = { page, source in
            AnalyticsReporter.track("settings_page_viewed", properties: [
                "page_id": page.analyticsValue,
                "source": source,
            ])
        },
        navigationSink: @escaping NavigationSink = { destination, previous, source in
            ProductUsageTelemetry.trackNavigation(destination: destination, previous: previous, source: source)
        }
    ) {
        self.pageViewSink = pageViewSink
        self.navigationSink = navigationSink
        self.selectedPage = selectedPage
        self.presentedPage = selectedPage
        self.presentationSource = "unknown"
    }
}

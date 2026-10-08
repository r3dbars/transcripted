import SwiftUI
import AppKit
import TranscriptedCore

@MainActor
final class TranscriptedSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let speakerPeopleModel: SpeakerPeopleSettingsViewModel
    private let navigationModel: TranscriptedSettingsNavigationModel
    /// Owned here, not by the view, so a closed window can hold Today's
    /// rebuilds and hand the newest one over before it shows again.
    private let todayViewModel: TodayViewModel
    private let hostingController: NSHostingController<TranscriptedSettingsView>

    init(appState: TranscriptedAppState, actions: TranscriptedSettingsActions) {
        let speakerDatabase = appState.meetingSession.speakerStoreForSettings()
        let speakerPeopleModel = SpeakerPeopleSettingsViewModel(
            speakerDatabase: speakerDatabase,
            transcriptDirectory: MeetingStoragePaths.transcriptsFolder,
            preferredClipsDirectory: MeetingStoragePaths.speakerClipsFolder,
            voiceprintMigrationGate: appState.meetingSession.speakerMigrationForSettings
        )
        self.speakerPeopleModel = speakerPeopleModel
        self.navigationModel = TranscriptedSettingsNavigationModel()
        let todayViewModel = TodayViewModel()
        self.todayViewModel = todayViewModel
        self.hostingController = NSHostingController(
            rootView: TranscriptedSettingsView(
                appState: appState,
                navigation: navigationModel,
                speakerPeopleModel: speakerPeopleModel,
                todayViewModel: todayViewModel,
                actions: actions
            )
        )

        let window = TranscriptedSettingsWindow.make(contentViewController: hostingController)
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(page: TranscriptedSettingsPage = .today, source: String = "unknown") {
        guard let window else { return }
        navigationModel.isWindowOpen = true
        speakerPeopleModel.setShown(true)
        speakerPeopleModel.refresh()
        navigationModel.presentedPage = page
        navigationModel.select(page, source: ProductUsageTelemetry.NavigationSource(rawValue: source) ?? .unknown)
        navigationModel.presentationSource = source
        navigationModel.presentationID = UUID()
        navigationModel.lastPresentedAt = Date()
        AnalyticsReporter.track(
            "settings_opened",
            properties: [
                "page_id": page.analyticsValue,
                "source": source,
            ]
        )
        // Publish anything Today built while closed before the first frame.
        todayViewModel.windowWillShow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens (or surfaces) the window on the Speakers page and asks the search
    /// field to take focus. Backs the ⌘F "Find Speaker" menu command.
    func focusSpeakerSearch(source: String) {
        present(page: .people, source: source)
        speakerPeopleModel.requestSearchFocus()
    }

    func focusHomeFind(source: String) {
        present(page: .home, source: source)
        navigationModel.requestHomeFindFocus()
    }

    /// Opens the Meetings page and, when a transcript is given, expands that
    /// meeting. Backs the Open button on a meeting in the Notch island.
    func revealMeeting(transcriptURL: URL?, source: String) {
        present(page: .home, source: source)
        if let transcriptURL {
            navigationModel.requestHomeRevealMeeting(transcriptURL: transcriptURL)
        }
    }

    func windowWillClose(_ notification: Notification) {
        SpeakerClipPlayback.stop()
        // Not a cancel: Home's search, playback and Today's data stay as they
        // are, so reopening shows the same window. Hidden work is gated on this.
        navigationModel.isWindowOpen = false
        speakerPeopleModel.setShown(false)
        todayViewModel.windowDidClose()
    }
}

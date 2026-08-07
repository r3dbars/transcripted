import SwiftUI
import AppKit
import TranscriptedCore

@MainActor
final class TranscriptedSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let speakerPeopleModel: SpeakerPeopleSettingsViewModel
    private let navigationModel: TranscriptedSettingsNavigationModel
    private let hostingController: NSHostingController<TranscriptedSettingsView>

    init(appState: TranscriptedAppState, actions: TranscriptedSettingsActions) {
        let speakerDatabase = (appState.meetingSession.services.speakerStore as? SpeakerDatabase)
            ?? SpeakerDatabase(path: SpeakerEmbedderFactory.activeSpeakerDBURL().path)
        let speakerPeopleModel = SpeakerPeopleSettingsViewModel(
            speakerDatabase: speakerDatabase,
            preferredClipsDirectory: MeetingStoragePaths.speakerClipsFolder
        )
        self.speakerPeopleModel = speakerPeopleModel
        self.navigationModel = TranscriptedSettingsNavigationModel()
        self.hostingController = NSHostingController(
            rootView: TranscriptedSettingsView(
                appState: appState,
                navigation: navigationModel,
                speakerPeopleModel: speakerPeopleModel,
                actions: actions
            )
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcripted Settings"
        window.titleVisibility = .hidden
        // Two-tone split runs edge-to-edge; the traffic lights float over the
        // sidebar tone (Things-style) instead of sitting in a toolbar band.
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar tells AppKit to use the taller titlebar
        // metrics, which insets the traffic lights from the top edge instead
        // of pinning them against it. The toolbar itself never shows items.
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.contentViewController = hostingController
        window.contentMinSize = NSSize(width: 880, height: 640)
        window.isReleasedWhenClosed = false
        // The reusable Settings shell can surface recent captures, speaker
        // review, and storage diagnostics, so keep the whole window protected.
        window.sharingType = .none
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(page: TranscriptedSettingsPage = .home, source: String = "unknown") {
        guard let window else { return }
        let presentedPage = page.consolidatedDestination
        speakerPeopleModel.refresh()
        navigationModel.presentedPage = page
        navigationModel.selectedPage = presentedPage
        navigationModel.presentationSource = source
        navigationModel.presentationID = UUID()
        AnalyticsReporter.track(
            "settings_opened",
            properties: [
                "page_id": presentedPage.analyticsValue,
                "source": source,
            ]
        )
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

    func windowWillClose(_ notification: Notification) {
        SpeakerClipPlayback.stop()
    }
}

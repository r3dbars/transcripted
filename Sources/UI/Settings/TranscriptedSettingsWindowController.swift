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
    /// After the first `present()`, `window.frame` is the user's position (or
    /// the placement we just applied). Before that, the constructor origin
    /// `(0, 0)` is not a saved frame — passing it in would keep the window
    /// in a corner.
    private var hasPlacedWindow = false

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

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(page: TranscriptedSettingsPage = .today, source: String = "unknown") {
        guard let window else { return }
        let frame = plannedFrame(for: window)
        if window.frame != frame {
            window.setFrame(frame, display: false)
        }
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
        // Recent macOS can ignore a pre-show setFrame and drop an unplaced
        // window in the bottom-trailing corner. Re-apply after orderFront.
        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func plannedFrame(for window: NSWindow) -> CGRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return window.frame }

        let visibleFrames = screens.map(\.visibleFrame)
        let mouse = NSEvent.mouseLocation
        let preferred = screens.first { NSMouseInRect(mouse, $0.frame, false) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? visibleFrames[0]

        let saved: CGRect?
        if hasPlacedWindow {
            saved = window.frame
        } else if window.setFrameUsingName(TranscriptedSettingsWindow.frameAutosaveName) {
            saved = window.frame
        } else {
            saved = nil
        }
        window.setFrameAutosaveName(TranscriptedSettingsWindow.frameAutosaveName)
        hasPlacedWindow = true

        let size = window.frame.size
        let windowSize = (size.width >= 1 && size.height >= 1)
            ? size
            : MainWindowFramePolicy.defaultSize
        return MainWindowFramePolicy.frame(
            savedFrame: saved,
            windowSize: windowSize,
            visibleFrames: visibleFrames,
            preferredVisibleFrame: preferred
        )
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

    /// Screen id the debug control surface reports. Nil when the window is closed.
    func automationScreenName() -> String? {
        navigationModel.isWindowOpen ? navigationModel.selectedPage.analyticsValue : nil
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

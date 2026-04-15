import AppKit
import SwiftUI
import TranscriptedCore

@MainActor
final class TranscriptedSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let speakerPeopleModel: SpeakerPeopleSettingsViewModel
    private let hostingController: NSHostingController<TranscriptedSettingsView>

    init(appState: TranscriptedAppState) {
        let speakerDatabase = (appState.meetingSession.services.speakerStore as? SpeakerDatabase)
            ?? SpeakerDatabase(path: MeetingStoragePaths.speakersDatabase.path)
        let speakerPeopleModel = SpeakerPeopleSettingsViewModel(
            speakerDatabase: speakerDatabase,
            preferredClipsDirectory: MeetingStoragePaths.speakerClipsFolder
        )
        self.speakerPeopleModel = speakerPeopleModel
        self.hostingController = NSHostingController(
            rootView: TranscriptedSettingsView(
                speakerPeopleModel: speakerPeopleModel,
                parakeetEngine: appState.sttRouter.parakeetEngine,
                meetingSession: appState.meetingSession,
                sparkleUpdater: appState.sparkleUpdater,
                onCheckForUpdates: { appState.sparkleUpdater.checkForUpdates() },
                onOpenAgentConnect: { AgentConnectionWindowCoordinator.shared.show() },
                onSendFeedback: { TranscriptedAppActions.sendFeedback(logEntries: appState.logger.entries) }
            )
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcripted Settings"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = MenuTokens.surfaceBackgroundNS
        window.minSize = NSSize(width: 860, height: 640)
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        guard let window else { return }
        speakerPeopleModel.refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        SpeakerClipPlayback.stop()
    }
}

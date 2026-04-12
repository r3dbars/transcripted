import SwiftUI
import AppKit
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
            transcriptsDirectory: MeetingStoragePaths.transcriptsFolder,
            preferredClipsDirectory: MeetingStoragePaths.speakerClipsFolder
        )
        self.speakerPeopleModel = speakerPeopleModel
        self.hostingController = NSHostingController(
            rootView: TranscriptedSettingsView(speakerPeopleModel: speakerPeopleModel)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcripted Settings"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
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

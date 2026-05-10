import SwiftUI
import AppKit
import Carbon
import TranscriptedCore

@MainActor
final class TranscriptedSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let speakerPeopleModel: SpeakerPeopleSettingsViewModel
    private let navigationModel: TranscriptedSettingsNavigationModel
    private let hostingController: NSHostingController<TranscriptedSettingsView>

    init(appState: TranscriptedAppState, actions: TranscriptedSettingsActions) {
        let speakerDatabase = (appState.meetingSession.services.speakerStore as? SpeakerDatabase)
            ?? SpeakerDatabase(path: MeetingStoragePaths.speakersDatabase.path)
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

        let window = TranscriptedSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcripted Settings"
        window.titleVisibility = .hidden
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(page: TranscriptedSettingsPage = .home, source: String = "unknown") {
        guard let window else { return }
        speakerPeopleModel.refresh()
        navigationModel.selectedPage = page
        navigationModel.presentationID = UUID()
        AnalyticsReporter.track(
            "settings_opened",
            properties: [
                "page_id": page.analyticsValue,
                "source": source,
            ]
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        SpeakerClipPlayback.stop()
    }
}

private final class TranscriptedSettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == UInt16(kVK_ANSI_W), modifiers.contains(.command) {
            performClose(nil)
            return
        }

        super.keyDown(with: event)
    }
}

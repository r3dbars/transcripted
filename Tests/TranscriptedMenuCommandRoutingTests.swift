import Foundation

/// Records which host entry point each menu action reached, in order.
@MainActor
private final class RecordingMenuCommandHost: TranscriptedMenuCommandHost {
    enum Call: Equatable {
        case closePopover
        case openSettings(TranscriptedSettingsPage, source: String)
        case startDictation
        case toggleMeetingRecording
        case importAudio
        case focusHomeFind(source: String)
        case focusSpeakerSearch(source: String)
    }

    var calls: [Call] = []

    func closeMenuBarPopover() { calls.append(.closePopover) }
    func openSettingsWindow(page: TranscriptedSettingsPage, source: String) { calls.append(.openSettings(page, source: source)) }
    func startDictationFromMenu() { calls.append(.startDictation) }
    func toggleMeetingRecordingFromMenu() { calls.append(.toggleMeetingRecording) }
    func importAudioFromMenu() { calls.append(.importAudio) }
    func focusHomeFindFromMenu(source: String) { calls.append(.focusHomeFind(source: source)) }
    func focusSpeakerSearchFromMenu(source: String) { calls.append(.focusSpeakerSearch(source: source)) }
}

@MainActor
private func route(_ action: TranscriptedMenuCommandCatalog.Action) -> [RecordingMenuCommandHost.Call] {
    let host = RecordingMenuCommandHost()
    TranscriptedMenuCommandCatalog.perform(action, on: host)
    return host.calls
}

@MainActor
func testTranscriptedMenuCommandRouting() async {
    runSuite("⌘, closes the popover, then opens the real Settings window on General") {
        assertEqual(
            route(TranscriptedMenuCommandCatalog.settings.action),
            [.closePopover, .openSettings(.general, source: "app_menu")],
            "the app-menu Settings item should open the owned window, reported as an app-menu open"
        )
    }

    runSuite("Capture commands reach the same entry points as the popover and triggers") {
        assertEqual(
            TranscriptedMenuCommandCatalog.capture.map { route($0.action) },
            [[.startDictation], [.toggleMeetingRecording], [.importAudio]],
            "⌘D, ⌘R and ⌘O should each run exactly one existing capture action"
        )
    }

    runSuite("Go commands open their page or focus search, reported as menu commands") {
        for item in TranscriptedMenuCommandCatalog.go {
            let expected: [RecordingMenuCommandHost.Call]
            switch item.action {
            case let .openPage(page):
                expected = [.openSettings(page, source: "menu_command")]
            case .findCaptures:
                expected = [.focusHomeFind(source: "menu_command")]
            case .findSpeaker:
                expected = [.focusSpeakerSearch(source: "menu_command")]
            default:
                assertTrue(false, "\(item.title) is in Go but isn't a page or a search")
                continue
            }
            assertEqual(route(item.action), expected, "\(item.title) should route to its own window action")
        }
        assertEqual(
            route(.findCaptures),
            [.focusHomeFind(source: "menu_command")],
            "Find Meetings… should focus Home's search"
        )
        assertEqual(
            route(.findSpeaker),
            [.focusSpeakerSearch(source: "menu_command")],
            "Find Speaker… should focus the Speakers search"
        )
    }

    runSuite("Only ⌘, closes the menu bar popover") {
        for item in TranscriptedMenuCommandCatalog.all where item.action != .openSettings {
            assertFalse(
                route(item.action).contains(.closePopover),
                "\(item.title) should leave the popover alone"
            )
        }
    }

    runSuite("The SwiftUI Settings scene is a recovery surface that opens the real window") {
        assertEqual(TranscriptedSettingsFallback.buttonTitle, "Open Settings", "the fallback scene should offer one visible action")
        assertEqual(
            TranscriptedSettingsFallback.buttonAutomationIdentifier,
            "transcripted.settings.fallback.open",
            "the fallback action should keep a stable automation identifier"
        )

        var steps: [String] = []
        TranscriptedSettingsFallback.open(
            dismiss: { steps.append("dismiss") },
            openSettings: { steps.append("open") }
        )
        assertEqual(steps, ["dismiss", "open"], "the fallback scene should close before the real window opens, so it never sits on top")
    }
}

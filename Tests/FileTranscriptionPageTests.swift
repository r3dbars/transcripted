import Foundation

// Promise: file import is an action on Meetings, not a sidebar place. The
// old `.files` page id still works for deep links, the debug channel and
// analytics, and lands on Meetings; the Terminal docs link lives on Agent.
@MainActor
func testFileTranscriptionPage() async {
    runSuite("The retired file page redirects to Meetings and leaves the sidebar") {
        assertFalse(SettingsSidebarSection.primarySection.pages.contains(.files), "the sidebar has six places, no file page")
        assertEqual(TranscriptedSettingsPage.files.redirected, .home, "a request for the file page opens Meetings")
        for page in TranscriptedSettingsPage.allCases where page != .files {
            assertEqual(page.redirected, page, "only the retired page moves")
        }
        assertEqual(TranscriptedSettingsPage.files.automationIdentifier, "transcripted.settings.sidebar.files",
                    "the old id stays stable for anything that still names it")
        assertEqual(TranscriptedSettingsPage.files.navigationShortcutKey, nil, "⌘O stays the keyboard entry for import")
    }

    runSuite("Selecting or presenting the file page lands on Meetings") {
        var navigations: [ProductUsageTelemetry.Destination] = []
        var views: [TranscriptedSettingsPage] = []
        let model = TranscriptedSettingsNavigationModel(
            selectedPage: .today,
            pageViewSink: { page, _ in views.append(page) },
            navigationSink: { destination, _, _ in navigations.append(destination) }
        )
        model.select(.files, source: .settingsAction)
        assertEqual(model.selectedPage, .home, "select lands on Meetings")
        model.select(.today, source: .sidebar)
        model.present(page: .files, source: "debug_control")
        assertEqual(model.selectedPage, .home, "present lands on Meetings")
        assertEqual(model.presentedPage, .home, "the presented page is Meetings too")
        assertFalse(navigations.contains(.files), "navigation never reports the retired destination")
        assertFalse(views.contains(.files), "page views never report the retired page")
    }

    runSuite("The Terminal docs link moved to the Agent page") {
        assertEqual(AgentConnectionGuide.cliDocumentationURL,
                    URL(string: "https://github.com/r3dbars/transcripted/blob/main/Tools/TranscriptedCLI/README.md")!,
                    "Agent links to the existing CLI import instructions")
    }
}

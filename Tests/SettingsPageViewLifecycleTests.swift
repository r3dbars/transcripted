import Foundation

@MainActor
func testSettingsPageViewLifecycle() {
    guard ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1" else {
        assertTrue(false, "Pure Settings telemetry fixtures require the file logger to be disabled")
        return
    }

    runSuite("Navigation model initialization does not manufacture a page view") {
        let fixture = SettingsPageViewFixture(page: .writing)
        assertEqual(fixture.model.selectedPage, .writing)
        assertEqual(fixture.model.presentedPage, .writing)
        assertEqual(fixture.model.presentationSource, "unknown")
        assertTrue(fixture.recorder.events.isEmpty)
    }

    runSuite("Presenting another page commits state and emits navigation then opened then one original-source page view") {
        let fixture = SettingsPageViewFixture(page: .people)
        let oldPresentation = fixture.model.presentationID
        var hookCalls = 0
        fixture.model.present(page: .general, source: "menu_bar") {
            hookCalls += 1
            assertEqual(fixture.model.selectedPage, .general)
            assertEqual(fixture.model.presentedPage, .general)
            assertEqual(fixture.model.presentationSource, "menu_bar")
            assertTrue(fixture.model.presentationID != oldPresentation)
            fixture.recorder.events.append(.opened(.general, "menu_bar"))
        }
        assertEqual(hookCalls, 1)
        assertEqual(fixture.recorder.events, [
            .navigation(.settings, .speakers, .menuBar),
            .opened(.general, "menu_bar"),
            .viewed(.general, "menu_bar")
        ])
    }

    runSuite("Repeated same-page presentations retain one correctly sourced page view per explicit opening") {
        let fixture = SettingsPageViewFixture(page: .home)
        let initialID = fixture.model.presentationID
        fixture.present(.home, source: "menu_bar")
        let firstID = fixture.model.presentationID
        fixture.present(.home, source: "dock_icon")
        let secondID = fixture.model.presentationID
        assertTrue(firstID != initialID)
        assertTrue(secondID != firstID)
        assertEqual(fixture.recorder.events, [
            .navigation(.meetings, .meetings, .menuBar),
            .opened(.home, "menu_bar"), .viewed(.home, "menu_bar"),
            .navigation(.meetings, .meetings, .dockIcon),
            .opened(.home, "dock_icon"), .viewed(.home, "dock_icon")
        ])
    }

    runSuite("A real page selection emits one navigation view and same-page selection retains only product navigation") {
        let fixture = SettingsPageViewFixture(page: .today)
        fixture.model.select(.writing, source: .sidebar)
        fixture.model.select(.writing, source: .sidebar)
        assertEqual(fixture.model.selectedPage, .writing)
        assertEqual(fixture.model.presentedPage, .today, "selection must not rewrite the presentation identity")
        assertEqual(fixture.recorder.events, [
            .navigation(.writing, .today, .sidebar), .viewed(.writing, "navigation"),
            .navigation(.writing, .writing, .sidebar)
        ])
    }

    runSuite("Returning to the originally presented page remains a real navigation page view") {
        let fixture = SettingsPageViewFixture(page: .today)
        fixture.present(.general, source: "app_menu")
        let presentationID = fixture.model.presentationID
        fixture.model.select(.people, source: .sidebar)
        fixture.model.select(.general, source: .sidebar)
        assertEqual(fixture.model.selectedPage, .general)
        assertEqual(fixture.model.presentedPage, .general)
        assertEqual(fixture.model.presentationID, presentationID)
        assertEqual(fixture.model.presentationSource, "app_menu")
        assertEqual(fixture.recorder.events, [
            .navigation(.settings, .today, .appMenu),
            .opened(.general, "app_menu"), .viewed(.general, "app_menu"),
            .navigation(.speakers, .settings, .sidebar), .viewed(.people, "navigation"),
            .navigation(.settings, .speakers, .sidebar), .viewed(.general, "navigation")
        ])
    }

    runSuite("Consecutive different-page presentations preserve each original page and source without render callbacks") {
        let fixture = SettingsPageViewFixture(page: .today)
        fixture.present(.people, source: "menu_command")
        fixture.present(.connectAgent, source: "app_menu")
        assertEqual(fixture.model.selectedPage, .connectAgent)
        assertEqual(fixture.model.presentedPage, .connectAgent)
        assertEqual(fixture.model.presentationSource, "app_menu")
        assertEqual(fixture.recorder.events, [
            .navigation(.speakers, .today, .menuCommand),
            .opened(.people, "menu_command"), .viewed(.people, "menu_command"),
            .navigation(.agent, .speakers, .appMenu),
            .opened(.connectAgent, "app_menu"), .viewed(.connectAgent, "app_menu")
        ])
    }

    runSuite("An unrecognized presentation source keeps existing typed navigation fallback and original page-view source") {
        let fixture = SettingsPageViewFixture(page: .home)
        // Synthetic value reaches only these injected in-memory sinks.
        fixture.present(.today, source: "synthetic_unrecognized")
        assertEqual(fixture.recorder.events, [
            .navigation(.today, .meetings, .unknown),
            .opened(.today, "synthetic_unrecognized"), .viewed(.today, "synthetic_unrecognized")
        ])
    }

    runSuite("The optional nonescaping hook does not gate a legitimate presentation page view") {
        let fixture = SettingsPageViewFixture(page: .today)
        fixture.model.present(page: .files, source: "menu_command")
        assertEqual(fixture.recorder.events, [
            .navigation(.files, .today, .menuCommand), .viewed(.files, "menu_command")
        ])
    }
}

private enum SettingsPageViewEvent: Equatable {
    case navigation(ProductUsageTelemetry.Destination, ProductUsageTelemetry.Destination,
                    ProductUsageTelemetry.NavigationSource)
    case opened(TranscriptedSettingsPage, String)
    case viewed(TranscriptedSettingsPage, String)
}

@MainActor
private final class SettingsPageViewRecorder {
    var events: [SettingsPageViewEvent] = []
}

@MainActor
private final class SettingsPageViewFixture {
    let recorder: SettingsPageViewRecorder
    let model: TranscriptedSettingsNavigationModel

    init(page: TranscriptedSettingsPage) {
        let recorder = SettingsPageViewRecorder()
        self.recorder = recorder
        // BOTH sinks are replaced. No reporter/default preference, discovery
        // helper, Settings view, window controller or SDK is called here.
        model = TranscriptedSettingsNavigationModel(
            selectedPage: page,
            pageViewSink: { page, source in recorder.events.append(.viewed(page, source)) },
            navigationSink: { destination, previous, source in
                recorder.events.append(.navigation(destination, previous, source))
            }
        )
    }

    func present(_ page: TranscriptedSettingsPage, source: String) {
        model.present(page: page, source: source) {
            recorder.events.append(.opened(page, source))
        }
    }
}

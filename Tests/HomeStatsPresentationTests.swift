import Foundation

func testHomeStatsPresentation() {
    runSuite("Home stats action uses the parent sheet presenter") {
        let homeSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/HomeView.swift"),
            encoding: .utf8
        )) ?? ""
        let settingsSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Settings/TranscriptedSettingsView.swift"),
            encoding: .utf8
        )) ?? ""

        assertTrue(
            homeSource.contains("transcripted.home.stats.view")
                && homeSource.contains(".help(\"View all stats\")"),
            "the home stats line should stay a labeled, scriptable stats affordance"
        )
        assertTrue(
            homeSource.contains("let onViewStats: () -> Void")
                && homeSource.contains("onViewStats()"),
            "home stats badge should send a view-stats intent"
        )
        assertFalse(
            homeSource.contains("@State private var isShowingDetails")
                || homeSource.contains(".sheet(isPresented: $isShowingDetails")
                || homeSource.contains(".popover(isPresented: $isShowingDetails"),
            "home stats badge should not own its own details presentation state"
        )
        assertTrue(
            settingsSource.contains("@State private var homeShowsStatsDetails = false")
                && settingsSource.contains(".sheet(isPresented: $homeShowsStatsDetails)")
                && settingsSource.contains("HomeStatsDetailSheet("),
            "settings root should own and present the stats detail sheet"
        )
    }
}

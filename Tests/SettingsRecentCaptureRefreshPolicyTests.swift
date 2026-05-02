import Foundation

func testSettingsRecentCaptureRefreshPolicy() {
    runSuite("SettingsRecentCaptureRefreshPolicy.mode — sends home to the dashboard loader") {
        assertEqual(
            SettingsRecentCaptureRefreshPolicy.mode(for: .home),
            .homeDashboard,
            "home should use the heavier dashboard refresh path"
        )
    }

    runSuite("SettingsRecentCaptureRefreshPolicy.mode — only loads recent lists for list pages") {
        assertEqual(
            SettingsRecentCaptureRefreshPolicy.mode(for: .meetings),
            .recentLists,
            "meetings should load the small recent list"
        )
        assertEqual(
            SettingsRecentCaptureRefreshPolicy.mode(for: .dictations),
            .recentLists,
            "dictations should load the small recent list"
        )
    }

    runSuite("SettingsRecentCaptureRefreshPolicy.mode — skips recent capture work on non-list pages") {
        for page in [TranscriptedSettingsPage.general, .models, .shortcuts, .people, .storage, .connectAgent, .privacy, .support, .about] {
            assertEqual(
                SettingsRecentCaptureRefreshPolicy.mode(for: page),
                .none,
                "\(page.rawValue) should not trigger capture scans"
            )
        }
    }
}

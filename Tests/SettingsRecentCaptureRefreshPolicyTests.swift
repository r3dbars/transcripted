import Foundation

func testSettingsRecentCaptureRefreshPolicy() {
    runSuite("SettingsRecentCaptureRefreshPolicy.mode — sends home to the dashboard loader") {
        assertEqual(
            SettingsRecentCaptureRefreshPolicy.mode(for: .home),
            .homeDashboard,
            "home should use the heavier dashboard refresh path"
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

    runSuite("TranscriptedSettingsPage keeps user-facing navigation metadata stable") {
        assertEqual(TranscriptedSettingsPage.connectAgent.analyticsValue, "connect_agent", "agent page analytics should stay snake_case")
        assertEqual(TranscriptedSettingsPage.connectAgent.title, "Agent", "agent page title should stay short")
        assertEqual(TranscriptedSettingsPage.people.title, "Speakers", "people page should stay focused on speaker naming")
        assertEqual(TranscriptedSettingsPage.privacy.systemImage, "lock.shield.fill", "privacy page should keep the shield affordance")
        assertEqual(
            Set(TranscriptedSettingsPage.allCases.map(\.rawValue)).count,
            TranscriptedSettingsPage.allCases.count,
            "settings page raw values should stay unique for selection persistence"
        )
    }

    runSuite("SettingsDashboardRefreshPolicy.shouldStartRefresh — allows the first passive refresh") {
        assertTrue(
            SettingsDashboardRefreshPolicy.shouldStartRefresh(
                force: false,
                isInFlight: false,
                lastStartedAt: nil,
                now: Date(timeIntervalSinceReferenceDate: 10)
            ),
            "home should refresh when there is no previous dashboard load"
        )
    }

    runSuite("SettingsDashboardRefreshPolicy.shouldStartRefresh — coalesces passive refresh churn") {
        let lastStartedAt = Date(timeIntervalSinceReferenceDate: 10)

        assertFalse(
            SettingsDashboardRefreshPolicy.shouldStartRefresh(
                force: false,
                isInFlight: true,
                lastStartedAt: lastStartedAt,
                now: Date(timeIntervalSinceReferenceDate: 12)
            ),
            "passive activation/navigation should not stack while dashboard work is in flight"
        )

        assertFalse(
            SettingsDashboardRefreshPolicy.shouldStartRefresh(
                force: false,
                isInFlight: false,
                lastStartedAt: lastStartedAt,
                now: Date(timeIntervalSinceReferenceDate: 11),
                minimumInterval: 1.5
            ),
            "passive refreshes inside the debounce window should be skipped"
        )

        assertTrue(
            SettingsDashboardRefreshPolicy.shouldStartRefresh(
                force: false,
                isInFlight: false,
                lastStartedAt: lastStartedAt,
                now: Date(timeIntervalSinceReferenceDate: 12),
                minimumInterval: 1.5
            ),
            "passive refreshes after the debounce window should run"
        )
    }

    runSuite("SettingsDashboardRefreshPolicy.shouldStartRefresh — treats the debounce boundary as refreshable") {
        assertTrue(
            SettingsDashboardRefreshPolicy.shouldStartRefresh(
                force: false,
                isInFlight: false,
                lastStartedAt: Date(timeIntervalSinceReferenceDate: 10),
                now: Date(timeIntervalSinceReferenceDate: 11.5),
                minimumInterval: 1.5
            ),
            "refreshes should be allowed exactly at the debounce boundary"
        )
    }

    runSuite("SettingsDashboardRefreshPolicy.shouldStartRefresh — forced capture changes bypass coalescing") {
        assertTrue(
            SettingsDashboardRefreshPolicy.shouldStartRefresh(
                force: true,
                isInFlight: true,
                lastStartedAt: Date(timeIntervalSinceReferenceDate: 10),
                now: Date(timeIntervalSinceReferenceDate: 10.2)
            ),
            "new/deleted captures should refresh even when passive refreshes would be skipped"
        )
    }

    runSuite("SettingsSpeakerQueueRefreshPolicy.shouldRefreshAfterMeetingTranscriptSave — refreshes on concrete saves") {
        assertTrue(
            SettingsSpeakerQueueRefreshPolicy.shouldRefreshAfterMeetingTranscriptSave(
                URL(fileURLWithPath: "/tmp/Transcripted/captures/meetings/example.md")
            ),
            "a newly saved meeting can add speaker review work, so the speaker queue should refresh"
        )

        assertFalse(
            SettingsSpeakerQueueRefreshPolicy.shouldRefreshAfterMeetingTranscriptSave(nil),
            "nil reset events should not trigger extra speaker queue work"
        )
    }
}

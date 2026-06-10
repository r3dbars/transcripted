import Foundation

func testSettingsRecentCaptureRefreshPolicy() {
    runSuite("SettingsRecentCaptureRefreshPolicy.mode — sends home to the dashboard loader") {
        for page in [TranscriptedSettingsPage.home, .meetings, .dictations] {
            assertEqual(
                SettingsRecentCaptureRefreshPolicy.mode(for: page),
                .homeDashboard,
                "\(page.rawValue) should use the heavier dashboard refresh path"
            )
        }
    }

    runSuite("SettingsRecentCaptureRefreshPolicy.mode — skips recent capture work on non-list pages") {
        for page in [TranscriptedSettingsPage.general, .models, .shortcuts, .people, .storage, .connectAgent, .beta, .privacy, .support, .about] {
            assertEqual(
                SettingsRecentCaptureRefreshPolicy.mode(for: page),
                .none,
                "\(page.rawValue) should not trigger capture scans"
            )
        }
    }

    runSuite("SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh — clicking Home starts only Home work") {
        let now = Date(timeIntervalSinceReferenceDate: 20)

        assertTrue(
            SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh(
                for: .home,
                force: false,
                isInFlight: false,
                lastStartedAt: nil,
                now: now
            ),
            "clicking Home should start the dashboard refresh path"
        )

        assertFalse(
            SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh(
                for: .people,
                force: false,
                isInFlight: false,
                lastStartedAt: nil,
                now: now
            ),
            "clicking Speakers should not run the Home recent-capture scan"
        )
    }

    runSuite("SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh — repeated Home clicks do not stack work") {
        let lastStartedAt = Date(timeIntervalSinceReferenceDate: 20)

        assertFalse(
            SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh(
                for: .home,
                force: false,
                isInFlight: true,
                lastStartedAt: lastStartedAt,
                now: Date(timeIntervalSinceReferenceDate: 20.4)
            ),
            "clicking Home again while a dashboard refresh is running should not start another one"
        )

        assertFalse(
            SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh(
                for: .home,
                force: false,
                isInFlight: false,
                lastStartedAt: lastStartedAt,
                now: Date(timeIntervalSinceReferenceDate: 20.8),
                minimumInterval: 1.5
            ),
            "clicking Home repeatedly inside the debounce window should stay cheap"
        )
    }

    runSuite("SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh — forced Home refresh bypasses passive gates") {
        assertTrue(
            SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh(
                for: .home,
                force: true,
                isInFlight: true,
                lastStartedAt: Date(timeIntervalSinceReferenceDate: 20),
                now: Date(timeIntervalSinceReferenceDate: 20.1)
            ),
            "new or deleted captures should refresh Home even when passive work would be coalesced"
        )
    }

    runSuite("SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh — force does not bypass page gating") {
        let now = Date(timeIntervalSinceReferenceDate: 20)

        for page in [TranscriptedSettingsPage.general, .models, .shortcuts, .people, .storage, .connectAgent, .beta, .privacy, .support, .about] {
            assertFalse(
                SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh(
                    for: page,
                    force: true,
                    isInFlight: false,
                    lastStartedAt: nil,
                    now: now
                ),
                "\(page.rawValue) should not run Home recent-capture work even for forced refresh events"
            )
        }
    }

    runSuite("SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh — passive Home refresh resumes after debounce") {
        assertTrue(
            SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh(
                for: .home,
                force: false,
                isInFlight: false,
                lastStartedAt: Date(timeIntervalSinceReferenceDate: 20),
                now: Date(timeIntervalSinceReferenceDate: 21.6),
                minimumInterval: 1.5
            ),
            "Home should refresh again once the passive debounce window has elapsed"
        )
    }

    runSuite("SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh — debounce boundary is refreshable on Home") {
        assertTrue(
            SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh(
                for: .home,
                force: false,
                isInFlight: false,
                lastStartedAt: Date(timeIntervalSinceReferenceDate: 20),
                now: Date(timeIntervalSinceReferenceDate: 21.5),
                minimumInterval: 1.5
            ),
            "Home should refresh at the exact passive debounce boundary"
        )
    }

    runSuite("TranscriptedSettingsPage keeps user-facing navigation metadata stable") {
        assertEqual(TranscriptedSettingsPage.connectAgent.analyticsValue, "connect_agent", "agent page analytics should stay snake_case")
        assertEqual(TranscriptedSettingsPage.connectAgent.title, "Agent", "agent page title should stay short")
        assertEqual(TranscriptedSettingsPage.beta.title, "Beta", "beta page title should stay short")
        assertEqual(TranscriptedSettingsPage.beta.systemImage, "wand.and.stars", "beta page should keep an experimental affordance")
        assertEqual(TranscriptedSettingsPage.people.title, "Speakers", "people page should stay focused on speaker naming")
        assertEqual(TranscriptedSettingsPage.privacy.systemImage, "lock.shield.fill", "privacy page should keep the shield affordance")
        assertEqual(TranscriptedSettingsPage.models.consolidatedDestination, .general, "models should now open inside General")
        assertEqual(TranscriptedSettingsPage.shortcuts.consolidatedDestination, .general, "shortcuts should now open inside General")
        assertEqual(TranscriptedSettingsPage.privacy.consolidatedDestination, .general, "privacy should now open inside General")
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

func testOnboardingAbandonmentReasonPolicy() {
    runSuite("OnboardingAbandonmentReasonPolicy distinguishes backgrounded exits from direct window closes") {
        assertEqual(
            OnboardingAbandonmentReasonPolicy.reason(pendingSystemSettingsHandoff: true),
            .backgrounded,
            "leaving Transcripted for a System Settings permission handoff and never returning should attribute the exit as backgrounded"
        )
        assertEqual(
            OnboardingAbandonmentReasonPolicy.reason(pendingSystemSettingsHandoff: false),
            .windowClosed,
            "closing onboarding without a pending permission handoff should keep the window-closed reason"
        )
    }
}

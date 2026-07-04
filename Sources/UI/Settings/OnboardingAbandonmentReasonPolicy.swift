enum OnboardingAbandonmentReasonPolicy {
    /// Onboarding leaves the app to hand a permission decision off to System
    /// Settings; if the user never returns before the flow ends, that's a
    /// distinct exit from directly closing the onboarding window.
    static func reason(
        pendingSystemSettingsHandoff: Bool
    ) -> ActivationTelemetry.WorkflowAbandonmentReasonKind {
        pendingSystemSettingsHandoff ? .backgrounded : .windowClosed
    }
}

// SingleInstanceReopenPolicy.swift
// Where a second launch sends the user. There's deliberately no alert case:
// an app-modal alert can sit hidden behind other windows and block the Stop
// command during capture, so reopening always lands on real controls.

enum SingleInstanceReopenSurface: Equatable, CaseIterable {
    /// Mid-onboarding there's no menu-bar home yet, so go back to onboarding.
    case onboarding
    /// The menu-bar popover with the recording controls.
    case popover
    /// No status item to anchor the popover, so open Settings instead.
    case settingsFallback
}

enum SingleInstanceReopenPolicy {
    static func surface(onboardingComplete: Bool, hasStatusItem: Bool) -> SingleInstanceReopenSurface {
        guard onboardingComplete else { return .onboarding }
        return hasStatusItem ? .popover : .settingsFallback
    }
}

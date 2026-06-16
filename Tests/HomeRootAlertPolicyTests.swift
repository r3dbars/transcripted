import Foundation

func testHomeRootAlertPolicy() {
    func states(
        confirmation: Bool = false,
        failure: Bool = false,
        retention: Bool = false
    ) -> HomeRootAlertStates {
        HomeRootAlertStates(
            hasDeleteConfirmation: confirmation,
            hasDeleteFailure: failure,
            hasAudioRetention: retention
        )
    }

    runSuite("HomeRootAlertPolicy presents nothing when no state is set") {
        assertNil(
            HomeRootAlertPolicy.activeSlot(states()),
            "no alert should present when none of the three states is set"
        )
    }

    runSuite("HomeRootAlertPolicy presents whichever single state is set") {
        assertEqual(
            HomeRootAlertPolicy.activeSlot(states(confirmation: true)),
            .deleteConfirmation,
            "a set delete confirmation should present"
        )
        assertEqual(
            HomeRootAlertPolicy.activeSlot(states(failure: true)),
            .deleteFailure,
            "a set delete failure should present"
        )
        assertEqual(
            HomeRootAlertPolicy.activeSlot(states(retention: true)),
            .audioRetention,
            "a set audio-retention prompt should present"
        )
    }

    runSuite("HomeRootAlertPolicy dismisses the confirmation first so a follow-up failure survives") {
        // Regression guard: a confirm action (e.g. dictation delete throws, or a
        // failed-meeting delete returns false) sets homeDeleteFailure *before*
        // SwiftUI writes nil to dismiss the confirmation. The confirmation
        // outranks the failure, so dismissal clears the confirmation and the
        // failure remains set to present next. If the binding cleared all three
        // states instead, the failure alert would never appear.
        assertEqual(
            HomeRootAlertPolicy.activeSlot(states(confirmation: true, failure: true)),
            .deleteConfirmation,
            "with both a confirmation and a freshly-raised failure set, the confirmation is dismissed first and the failure is left to present"
        )
    }

    runSuite("HomeRootAlertPolicy keeps a deterministic order across all states") {
        assertEqual(
            HomeRootAlertPolicy.activeSlot(states(confirmation: true, failure: true, retention: true)),
            .deleteConfirmation,
            "confirmation outranks failure and audio retention"
        )
        assertEqual(
            HomeRootAlertPolicy.activeSlot(states(failure: true, retention: true)),
            .deleteFailure,
            "failure outranks audio retention"
        )
    }
}

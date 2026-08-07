import Foundation
import Observation

@Observable
@MainActor
final class TranscriptedSettingsNavigationModel {
    var selectedPage: TranscriptedSettingsPage
    var presentedPage: TranscriptedSettingsPage
    var presentationSource: String
    var presentationID = UUID()

    /// Bumped by ⌘F (Find Captures). Home reveals and focuses its find bar
    /// via `.task(id:)` on this token, which also fires on mount — so the
    /// request survives navigating to Home from another page (a plain
    /// notification would be posted before Home's subscriber exists).
    var homeFindFocusToken = 0

    func requestHomeFindFocus() {
        homeFindFocusToken += 1
    }

    init(selectedPage: TranscriptedSettingsPage = .home) {
        self.selectedPage = selectedPage
        self.presentedPage = selectedPage
        self.presentationSource = "unknown"
    }
}

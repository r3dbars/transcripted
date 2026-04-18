import Foundation
import Observation

@Observable
@MainActor
final class TranscriptedSettingsNavigationModel {
    var selectedPage: TranscriptedSettingsPage

    init(selectedPage: TranscriptedSettingsPage = .home) {
        self.selectedPage = selectedPage
    }
}

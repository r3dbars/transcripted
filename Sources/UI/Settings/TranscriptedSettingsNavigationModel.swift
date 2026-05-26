import Foundation
import Observation

@Observable
@MainActor
final class TranscriptedSettingsNavigationModel {
    var selectedPage: TranscriptedSettingsPage
    var presentedPage: TranscriptedSettingsPage
    var presentationID = UUID()

    init(selectedPage: TranscriptedSettingsPage = .home) {
        self.selectedPage = selectedPage
        self.presentedPage = selectedPage
    }
}

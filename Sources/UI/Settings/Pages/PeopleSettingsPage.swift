import SwiftUI

/// The Settings > Speakers ("People") page. Extracted from
/// `TranscriptedSettingsView` (codebase audit 2026-07-08 wave 2, spec W2-A).
struct PeopleSettingsPage: View {
    @ObservedObject var speakerPeopleModel: SpeakerPeopleSettingsViewModel
    let onStartMeeting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Speakers",
                summary: "Name new voices and manage the people in your meetings."
            )

            SpeakerPeopleSettingsSection(
                model: speakerPeopleModel,
                onStartMeeting: onStartMeeting
            )
        }
        .accessibilityIdentifier("transcripted.settings.page.people")
    }
}

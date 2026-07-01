import SwiftUI

extension TranscriptedSettingsView {
    var peoplePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Speakers",
                summary: "Name new voices and manage the people in your meetings."
            )

            SpeakerPeopleSettingsSection(model: speakerPeopleModel)
        }
        .accessibilityIdentifier("transcripted.settings.page.people")
    }
}

import SwiftUI

/// The Settings > Speakers ("People") page. Extracted from
/// `TranscriptedSettingsView` (codebase audit 2026-07-08 wave 2, spec W2-A).
struct PeopleSettingsPage: View {
    @ObservedObject var speakerPeopleModel: SpeakerPeopleSettingsViewModel
    let onStartMeeting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // What the voice prints mean, once, above everything else.
            SettingsPageIntro(title: "Speakers", summary: SpeakerPrintDirectory.headerLine)

            SpeakerPeopleSettingsSection(
                model: speakerPeopleModel,
                onStartMeeting: onStartMeeting
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.page.people")
    }
}

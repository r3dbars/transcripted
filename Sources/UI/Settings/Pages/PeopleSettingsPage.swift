import SwiftUI

/// The Settings > Speakers ("People") page. Extracted from
/// `TranscriptedSettingsView` (codebase audit 2026-07-08 wave 2, spec W2-A).
struct PeopleSettingsPage: View {
    @ObservedObject var speakerPeopleModel: SpeakerPeopleSettingsViewModel
    let onStartMeeting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Title only — the "Needs a name" section's own helper line
            // already explains the page's job, so a subtitle here would just
            // say it twice.
            SettingsPageIntro(title: "Speakers")

            SpeakerPeopleSettingsSection(
                model: speakerPeopleModel,
                onStartMeeting: onStartMeeting
            )
        }
        .accessibilityIdentifier("transcripted.settings.page.people")
    }
}

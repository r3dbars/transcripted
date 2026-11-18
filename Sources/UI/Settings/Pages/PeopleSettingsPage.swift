import SwiftUI

/// The Settings > Speakers page: the title with one line beside it, then the
/// "Who spoke?" card and the people Transcripted knows. Extracted from
/// `TranscriptedSettingsView` (codebase audit 2026-07-08 wave 2, spec W2-A).
struct PeopleSettingsPage: View {
    @ObservedObject var speakerPeopleModel: SpeakerPeopleSettingsViewModel
    let onStartMeeting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Speakers")
                    .font(LibraryTokens.title)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Text(SpeakerPrintDirectory.headerLine)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
            }

            SpeakerPeopleSettingsSection(
                model: speakerPeopleModel,
                onStartMeeting: onStartMeeting
            )

            CallSpeakerNamesToggleRow()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.page.people")
    }
}

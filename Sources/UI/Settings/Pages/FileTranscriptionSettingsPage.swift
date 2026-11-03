import SwiftUI

/// A discoverable entry to the existing import queue. Progress comes from the
/// shared meeting session; saved transcripts and retry rows stay in Meetings.
struct FileTranscriptionSettingsPage<Activity: View>: View {
    let onImportAudioFile: () -> Void
    let onShowMeetings: () -> Void
    @ViewBuilder let activity: () -> Activity

    static var cliDocumentationURL: URL {
        URL(string: "https://github.com/r3dbars/transcripted/blob/main/Tools/TranscriptedCLI/README.md")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Transcribe a file")
                    .font(LibraryTokens.title)
                Text("Turn audio or video into a transcript on this Mac. Choose one or more files; Transcripted works through them one at a time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Choose audio or video…", action: onImportAudioFile)
                .buttonStyle(.borderedProminent)
                .help("Choose files to transcribe. You can also use ⌘O.")
                .accessibilityIdentifier("transcripted.settings.files.choose")

            activity()

            VStack(alignment: .leading, spacing: 8) {
                Text("Transcripts appear in Meetings. Open it to read a transcript or retry a saved recording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("View transcripts and retries", action: onShowMeetings)
                    .accessibilityIdentifier("transcripted.settings.files.meetings")
            }

            Link("CLI documentation", destination: Self.cliDocumentationURL)
                .font(.callout)
                .help("Import files from Terminal or automate a folder workflow")
                .accessibilityIdentifier("transcripted.settings.files.cli-docs")
        }
        .accessibilityIdentifier("transcripted.settings.page.files")
    }
}

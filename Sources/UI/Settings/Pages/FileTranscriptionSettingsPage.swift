import SwiftUI

/// A discoverable entry to the existing import queue. Progress comes from the
/// shared meeting session; saved transcripts and retry rows stay in Meetings.
///
/// Meetings now does all of this itself (its header's Transcribe a file…,
/// a drop anywhere on the page, the same activity row), so this page can
/// go once the sidebar points `.files` at Meetings.
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
                Text("Turn audio or video into a transcript on this Mac. Choose one or more files, or drop them on Meetings; Transcripted works through them one at a time.")
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(HomeCaptureListCopy.TranscribeFileAction.title, action: onImportAudioFile)
                .buttonStyle(.transcriptedPrimary)
                .help("Choose files to transcribe. You can also use ⌘O.")
                .accessibilityIdentifier("transcripted.settings.files.choose")

            activity()

            VStack(alignment: .leading, spacing: 8) {
                Text("Transcripts appear in Meetings.")
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Meetings", action: onShowMeetings)
                    .buttonStyle(.transcriptedSecondary)
                    .accessibilityIdentifier("transcripted.settings.files.meetings")
            }

            Link("CLI documentation", destination: Self.cliDocumentationURL)
                .font(LibraryTokens.meta)
                .help("Import files from Terminal or automate a folder workflow")
                .accessibilityIdentifier("transcripted.settings.files.cli-docs")
        }
        .accessibilityIdentifier("transcripted.settings.page.files")
    }
}

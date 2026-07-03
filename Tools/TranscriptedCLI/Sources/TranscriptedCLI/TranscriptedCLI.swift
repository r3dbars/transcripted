import ArgumentParser

@main
struct TranscriptedCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcripted-cli",
        abstract: "Transcripted command-line tools for local transcription, diarization, and local context.",
        version: "0.1.0",
        subcommands: [
            Transcribe.self,
            Diarize.self,
            Batch.self,
            ContextRecent.self,
            ContextSearch.self,
            ReadMeeting.self,
            ListDictations.self,
            ReadDictation.self,
            ListTimelines.self,
            ReadTimeline.self,
        ]
    )
}

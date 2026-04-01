import ArgumentParser

@main
struct TranscriptedCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcripted-cli",
        abstract: "Offline diarization CLI for FluidAudio.",
        version: "0.1.0",
        subcommands: [Diarize.self, Batch.self]
    )
}

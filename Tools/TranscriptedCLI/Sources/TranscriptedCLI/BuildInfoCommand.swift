import ArgumentParser
import Foundation

/// No model loads, network, or user paths. Packaging checks the executable's
/// compiled capabilities, rather than trusting the requested build environment.
struct BuildInfo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-info",
        abstract: "Print compiled CLI capabilities as JSON."
    )

    struct Capabilities: Codable, Equatable {
        let mode: String
        let transcription: Bool
        let diarization: Bool
        let meetingImport: Bool
    }

    static var capabilities: Capabilities {
        #if TRANSCRIPTEDCLI_WITH_TRANSCRIPTION && canImport(FluidAudio)
        let transcription = true
        #else
        let transcription = false
        #endif
        #if TRANSCRIPTEDCLI_WITH_DIARIZATION && canImport(FluidAudio)
        let diarization = true
        #else
        let diarization = false
        #endif
        #if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT
        let meetingImport = true
        #else
        let meetingImport = false
        #endif
        return Capabilities(
            mode: meetingImport ? "meeting" : (transcription || diarization ? "audio" : "retrieval"),
            transcription: transcription,
            diarization: diarization,
            meetingImport: meetingImport
        )
    }

    func run() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Self.capabilities)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

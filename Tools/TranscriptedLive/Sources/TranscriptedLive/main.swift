import FluidAudio
import Foundation
import TranscriptedLiveCore

let usage = """
transcripted-live: live meeting transcription for the Claude Code mod (experiment)

  transcripted-live watch [--recordings DIR] [--chunk 160|320|1280] [--pause-ms 640]
      Wait for Transcripted to record a meeting and transcribe it live.

  transcripted-live replay FILE [--as you|them] [--mic FILE] [--system FILE]
                           [--speed N] [--title TEXT] [--chunk 160|320|1280]
      Play audio files through the live path as a pretend meeting.
      --speed 1 is real time (default), 0 is as fast as possible.

  transcripted-live status
      Print the helper's session.json.

Output: \(LiveOutput.defaultRoot.path)
"""

var arguments = Array(CommandLine.arguments.dropFirst())
// Whoever started us. The mod sets TRANSCRIPTED_LIVE_EXIT_WITH_PARENT=1, so a
// helper whose Claude Code session went away stops between meetings instead
// of idling on, reparented to launchd.
let launchParent = getppid()
let exitWithParent = ProcessInfo.processInfo.environment["TRANSCRIPTED_LIVE_EXIT_WITH_PARENT"] == "1"

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func log(_ line: String) {
    print(line)
    fflush(stdout)
}

guard let command = arguments.first else { fail(usage) }
arguments.removeFirst()

let chunkSize: StreamingChunkSize
let chunkName: String
switch option("--chunk") ?? "320" {
case "160": (chunkSize, chunkName) = (.ms160, "160ms")
case "1280": (chunkSize, chunkName) = (.ms1280, "1280ms")
default: (chunkSize, chunkName) = (.ms320, "320ms")
}
// FluidAudio's durationMs is the window size (630 for the 320ms mode), not the mode name.
let modelLabel = "parakeet-eou \(chunkName)"

if command == "status" {
    let url = LiveOutput.defaultRoot.appendingPathComponent("session.json")
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "no session.json yet"
    print(text)
    exit(0)
}

guard command == "watch" || command == "replay" else { fail(usage) }

let output: LiveOutput
do {
    output = try LiveOutput(model: modelLabel)
} catch let error as LiveOutputError {
    fail("\(error)")
} catch {
    fail("can't write \(LiveOutput.defaultRoot.path): \(error)")
}
// How long a speaker must pause before their line is final (FluidAudio's default is 1280).
let pauseMs = Int(option("--pause-ms") ?? "640") ?? 640
let runner = LiveRunner(output: output, chunkSize: chunkSize, pauseMs: pauseMs, log: log)

let work = Task {
    do {
        try await runner.loadModels()
        if command == "watch" {
            let directory = option("--recordings").map { URL(fileURLWithPath: $0) }
                ?? RecordingLocator.defaultRecordingsDirectory
            try await runner.watch(recordingsDirectory: directory) {
                LiveRunner.parentIsGone(launchParent: launchParent, currentParent: getppid(), isEnabled: exitWithParent)
            }
        } else {
            let speed = Double(option("--speed") ?? "1") ?? 1
            let title = option("--title")
            let singleSpeaker = option("--as") ?? "them"
            var tracks: [LiveRunner.ReplayTrack] = []
            if let mic = option("--mic") { tracks.append(.init(url: URL(fileURLWithPath: mic), speaker: "you")) }
            if let system = option("--system") { tracks.append(.init(url: URL(fileURLWithPath: system), speaker: "them")) }
            if let file = arguments.first { tracks.append(.init(url: URL(fileURLWithPath: file), speaker: singleSpeaker)) }
            guard !tracks.isEmpty else { fail(usage) }
            try await runner.replay(tracks, speed: speed, title: title)
        }
    } catch is CancellationError {
    } catch {
        log("error: \(error)")
    }
    output.shutdown()
    exit(0)
}

// Ctrl-C: mark the session over so the mod stops showing a live meeting.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        output.shutdown()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()

// Opt-in live check for on-device meeting titles (not part of CI).
// Runs the real llama-server helper against a fictional meeting copied into
// a temp folder, prints the model's raw JSON, the guarded label, and the
// frontmatter the app would write. Built and run by
// scripts/dev/meeting-titles-live-check.sh.

import Foundation

@main
struct MeetingTitlesLiveCheck {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let modelPath = value("--model"), let helperPath = value("--helper"), let fixturePath = value("--fixture") else {
            fputs("usage: --model <gguf> --helper <llama-server> --fixture <meeting.md> [--port N]\n", stderr)
            exit(2)
        }
        let port = value("--port").flatMap(Int.init) ?? MeetingTitlesLlamaServer.defaultPort + 100

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-titles-live-check-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let meetingURL = scratch.appendingPathComponent("2026-03-04 Meeting with Priya and Marcus.md")
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: fixturePath), to: meetingURL)
        } catch {
            fputs("could not copy the fixture\n", stderr)
            exit(1)
        }

        let server = MeetingTitlesLlamaServer(
            configuration: .init(helperURL: URL(fileURLWithPath: helperPath), port: port, requiresBundleSeal: false),
            openModel: {
                guard let handle = FileHandle(forReadingAtPath: modelPath) else { throw MeetingTitlesEngineError.helperMissing }
                return handle
            }
        )

        let raw = (try? String(contentsOf: meetingURL, encoding: .utf8)) ?? ""
        guard let turns = MeetingTitlesLabeler.labelableTurns(fromMeetingMarkdown: raw) else {
            print("fixture is too short to label")
            exit(1)
        }
        print("== transcript sent to the model (\(turns.count) turns, \(MeetingTitlesTranscript.wordCount(turns)) words)")
        print(MeetingTitlesTranscript.render(turns))

        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            let engine = try await server.start()
            let launched = clock.now
            print("\n== helper ready in \(launched - startedAt)")
            let systemTokens = try await engine.countTokens(MeetingTitlesPrompt.system)
            let fitted = try await MeetingTitlesFit.fit(turns, systemTokens: systemTokens) { try await engine.countTokens($0) }
            print("== prompt: system \(systemTokens) tokens, transcript \(fitted.tokenCount) tokens, dropped turns \(fitted.droppedTurns)")
            let body = MeetingTitlesPrompt.chatRequestBody(transcript: fitted.transcript)
            let reply = try await engine.chat(body: body)
            print("== model reply in \(clock.now - launched)")
            print(reply)

            let label = MeetingTitlesGuards.label(fromModelReply: reply)
            print("\n== after guards")
            print("title:   \(label?.title ?? "(none, keeps the app's title)")")
            print("line:    \(label?.line ?? "(none)")")
            print("summary: \(label?.summary ?? "(none)")")

            // The real job path: same runner, writer and serializer the app uses.
            let result = await MeetingTitlesJobRunner.run(
                MeetingTitlesJob(transcriptURL: meetingURL, titleRule: .appMade("Meeting with Priya and Marcus")),
                host: server
            )
            print("\n== job result: \(result)")
            let saved = (try? String(contentsOf: meetingURL, encoding: .utf8)) ?? ""
            let frontmatter = saved.components(separatedBy: "\n---\n").first ?? ""
            print("== frontmatter written")
            print(frontmatter + "\n---")
            let bodyUnchanged = TranscriptFrontmatter.body(in: saved) == TranscriptFrontmatter.body(in: raw)
            print("== body unchanged: \(bodyUnchanged)")
        } catch {
            print("live check failed: \(error)")
            await server.stop()
            exit(1)
        }
        await server.stop()
        print("== helper stopped: \(!server.isRunning)")
    }
}

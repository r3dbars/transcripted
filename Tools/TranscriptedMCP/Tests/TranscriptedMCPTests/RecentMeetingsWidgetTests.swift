import MCP
import XCTest
@testable import transcripted_mcp

/// Covers the MCP Apps (SEP-1865) recent-meetings widget: the data builder that
/// reads the local capture library, the self-contained HTML renderer, and the
/// `show_recent_meetings` tool result / `ui://` resource wire shape.
final class RecentMeetingsWidgetTests: XCTestCase {
    var index: TranscriptIndex!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = makeTempDir()
        index = try! TranscriptIndex(indexDir: tempDir)
    }

    override func tearDown() {
        index = nil
        removeTempDir(tempDir)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Write a `<stem>_audio/<track>.<ext>` file next to a fixture meeting,
    /// mirroring the app's `audio/<stem>_audio/` layout.
    @discardableResult
    private func writeAudio(stem: String, track: String, ext: String, bytes: Int) throws -> URL {
        let dir = tempDir
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("\(stem)_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(track).\(ext)")
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    private func model(count: Int = 5, perMeetingCap: Int? = nil, totalCap: Int? = nil) throws -> RecentMeetingsWidgetModel {
        try RecentMeetingsWidgetBuilder.build(
            index: index,
            meetingDirs: [tempDir],
            count: count,
            generatedDate: "2026-07-07",
            serverName: "transcripted",
            serverVersion: "test",
            maxAudioBytesPerMeeting: perMeetingCap ?? RecentMeetingsWidgetBuilder.defaultMaxAudioBytesPerMeeting,
            maxAudioBytesTotal: totalCap ?? RecentMeetingsWidgetBuilder.defaultMaxAudioBytesTotal
        )
    }

    // MARK: - Builder

    func testBuildEmbedsTranscriptAndAudioForRecentMeeting() throws {
        try writeFixture(
            makeFixtureJSON(title: "Roadmap Sync", date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11", to: tempDir
        )
        try writeAudio(stem: "Call_2026-03-26_16-04-11", track: "playback", ext: "m4a", bytes: 2048)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let m = try model()
        XCTAssertEqual(m.meetings.count, 1)
        let meeting = m.meetings[0]
        XCTAssertEqual(meeting.title, "Roadmap Sync")
        XCTAssertFalse(meeting.transcript.isEmpty, "transcript should be embedded")
        XCTAssertTrue(meeting.transcript.contains("roadmap") || meeting.transcript.contains("Good morning"),
                      "transcript should carry dialogue text")

        let audio = try XCTUnwrap(meeting.audio, "preferred audio track should be embedded")
        XCTAssertEqual(audio.mimeType, "audio/mp4")
        XCTAssertEqual(audio.label, "Mix", "playback stem maps to the Mix label")
        XCTAssertTrue(audio.dataURI.hasPrefix("data:audio/mp4;base64,"))
        XCTAssertNil(meeting.audioNote)
    }

    func testBuildPrefersMixOverMicWhenBothPresent() throws {
        try writeFixture(makeFixtureJSON(date: "2026-03-26T16:04:11-0500"),
                         filename: "Call_2026-03-26_16-04-11", to: tempDir)
        try writeAudio(stem: "Call_2026-03-26_16-04-11", track: "microphone", ext: "m4a", bytes: 1024)
        try writeAudio(stem: "Call_2026-03-26_16-04-11", track: "playback", ext: "m4a", bytes: 1024)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let audio = try XCTUnwrap(try model().meetings[0].audio)
        XCTAssertEqual(audio.label, "Mix", "playback (Mix) is preferred over microphone")
    }

    func testBuildFallsBackToPathWhenAudioTooLarge() throws {
        try writeFixture(makeFixtureJSON(date: "2026-03-26T16:04:11-0500"),
                         filename: "Call_2026-03-26_16-04-11", to: tempDir)
        try writeAudio(stem: "Call_2026-03-26_16-04-11", track: "playback", ext: "m4a", bytes: 5_000_000)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let meeting = try model(perMeetingCap: 1_000_000).meetings[0]
        XCTAssertNil(meeting.audio, "oversized audio is not inlined")
        XCTAssertNotNil(meeting.audioNote)
        XCTAssertTrue(meeting.audioNote?.contains("too large") == true)
        XCTAssertNotNil(meeting.audioDirectory, "path fallback is provided")
    }

    func testBuildTotalBudgetStopsInliningAcrossMeetings() throws {
        for i in 0..<3 {
            let stem = "Call_2026-03-2\(i)_10-00-00"
            try writeFixture(makeFixtureJSON(date: "2026-03-2\(i)T10:00:00-0500"), filename: stem, to: tempDir)
            try writeAudio(stem: stem, track: "playback", ext: "m4a", bytes: 700_000)
        }
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        // Budget fits one 700KB track, not all three.
        let embedded = try model(perMeetingCap: 1_000_000, totalCap: 1_000_000).meetings.filter { $0.audio != nil }
        XCTAssertEqual(embedded.count, 1, "total budget caps inline audio across cards")
    }

    func testBuildHandlesMeetingWithNoAudio() throws {
        try writeFixture(makeFixtureJSON(date: "2026-03-26T16:04:11-0500"),
                         filename: "Call_2026-03-26_16-04-11", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let meeting = try model().meetings[0]
        XCTAssertNil(meeting.audio)
        XCTAssertNil(meeting.audioDirectory, "no audio directory exists")
        XCTAssertEqual(meeting.audioNote, "No recording found")
        XCTAssertFalse(meeting.transcript.isEmpty)
    }

    // MARK: - HTML renderer

    func testHTMLIsSelfContainedAndThemeAware() throws {
        try writeFixture(makeFixtureJSON(title: "Roadmap Sync", date: "2026-03-26T16:04:11-0500"),
                         filename: "Call_2026-03-26_16-04-11", to: tempDir)
        try writeAudio(stem: "Call_2026-03-26_16-04-11", track: "playback", ext: "m4a", bytes: 2048)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let html = RecentMeetingsWidget.html(for: try model())

        // Self-contained: no external network references of any kind.
        XCTAssertFalse(html.contains("http://"), "no external http references")
        XCTAssertFalse(html.contains("https://"), "no external https references")
        XCTAssertFalse(html.contains("//cdn"), "no CDN references")
        XCTAssertFalse(html.range(of: #"src\s*=\s*["']https?:"#, options: .regularExpression) != nil)

        // Theme-aware in both directions.
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(html.contains(#"[data-theme="dark"]"#))
        XCTAssertTrue(html.contains(#"[data-theme="light"]"#))

        // Data is baked in and the audio data URI rides along.
        XCTAssertTrue(html.contains(#"id="tx-data""#))
        XCTAssertTrue(html.contains("data:audio/mp4;base64,"))
        XCTAssertTrue(html.contains("Roadmap Sync"))
    }

    func testHTMLNeutralizesScriptClose() throws {
        // A malicious/odd title must not be able to close the data <script> tag.
        try writeFixture(makeFixtureJSON(title: "Evil </script><img> Meeting", date: "2026-03-26T16:04:11-0500"),
                         filename: "Call_2026-03-26_16-04-11", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let html = RecentMeetingsWidget.html(for: try model())
        // The JSON payload escapes "</" so the data block cannot be broken out of.
        XCTAssertFalse(html.contains("</script><img>"), "script-close sequence must be neutralized in the data block")
        XCTAssertTrue(html.contains(#"<\/script>"#))
    }

    // MARK: - Resource + tool wire shape (MCP Apps / SEP-1865)

    func testResourceDescriptorShape() {
        let resource = TranscriptedUIResources.recentMeetingsResource
        XCTAssertEqual(resource.uri, "ui://transcripted/recent-meetings.html")
        XCTAssertEqual(resource.mimeType, "text/html;profile=mcp-app")
        XCTAssertNotNil(resource._meta?["ui"], "resource carries MCP Apps ui metadata")
    }

    func testToolMetaLinksToUIResource() {
        let meta = TranscriptedUIResources.toolMeta
        // Official extension linkage.
        if case .object(let ui)? = meta["ui"] {
            XCTAssertEqual(ui["resourceUri"], .string("ui://transcripted/recent-meetings.html"))
        } else {
            XCTFail("tool _meta.ui.resourceUri missing")
        }
        // OpenAI Apps SDK alias for ChatGPT.
        XCTAssertEqual(meta["openai/outputTemplate"], .string("ui://transcripted/recent-meetings.html"))
    }

    func testShowRecentMeetingsResultShape() throws {
        try writeFixture(makeFixtureJSON(title: "Roadmap Sync", date: "2026-03-26T16:04:11-0500"),
                         filename: "Call_2026-03-26_16-04-11", to: tempDir)
        try writeAudio(stem: "Call_2026-03-26_16-04-11", track: "playback", ext: "m4a", bytes: 2048)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let directories = TranscriptedDataDirectories(
            meetingDirs: [tempDir], dictationDirs: [tempDir], indexDir: tempDir
        )
        let result = try TranscriptedUIResources.showRecentMeetingsResult(
            count: 5, index: index, directories: directories, serverVersion: "test"
        )

        XCTAssertEqual(result.isError, false)

        // Text fallback for non-rendering clients (e.g. the Claude Code CLI).
        let text = result.content.compactMap { c -> String? in
            if case .text(let t, _, _) = c { return t }
            return nil
        }.first
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("Roadmap Sync") == true)

        // Inline embedded UI resource carries the widget HTML at the ui:// URI.
        let embedded = result.content.compactMap { c -> Resource.Content? in
            if case .resource(let r, _, _) = c { return r }
            return nil
        }.first
        let res = try XCTUnwrap(embedded, "tool result should carry an embedded ui resource")
        XCTAssertEqual(res.uri, "ui://transcripted/recent-meetings.html")
        XCTAssertEqual(res.mimeType, "text/html;profile=mcp-app")
        XCTAssertTrue(res.text?.contains("<!DOCTYPE html>") == true)
        XCTAssertTrue(res.text?.contains("data:audio/mp4;base64,") == true)

        // structuredContent so a spec host can push tool output into the template.
        XCTAssertNotNil(result.structuredContent)

        // Result _meta links back to the resource.
        XCTAssertNotNil(result._meta?["ui"])
    }

    func testTextFallbackListsMeetings() throws {
        let m = RecentMeetingsWidgetModel(
            serverName: "transcripted", serverVersion: "test", generatedDate: "2026-07-07",
            meetings: [
                WidgetMeeting(title: "Roadmap Sync", date: "2026-03-26", datetime: "2026-03-26T16:04:11",
                              durationSeconds: 1800, speakers: ["You", "Jenny"], wordCount: 1200,
                              filename: "Call_2026-03-26_16-04-11", transcript: "hi",
                              audio: WidgetAudio(dataURI: "data:audio/mp4;base64,AA==", mimeType: "audio/mp4", label: "Mix", sizeBytes: 2),
                              audioDirectory: nil, audioNote: nil)
            ]
        )
        let text = TranscriptedUIResources.textFallback(for: m)
        XCTAssertTrue(text.contains("Roadmap Sync"))
        XCTAssertTrue(text.contains("30:00"))
        XCTAssertTrue(text.contains("▶ audio"))
    }
}

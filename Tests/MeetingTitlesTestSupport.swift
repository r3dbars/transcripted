import Foundation

/// Fakes and fixtures shared by the meeting titles tests. No test here needs
/// the real model, the helper binary or the network.

/// Counts tokens as words and answers every chat with `reply`.
final class FakeTitlesEngine: MeetingTitlesEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var replyText: String
    private var bodies: [Data] = []
    var failChat = false

    init(reply: String = FakeTitlesEngine.goodReply) {
        replyText = reply
    }

    static let goodReply = #"{"title": "Vendor contract renewal", "line": "The team chose to renew with the current vendor for one year.", "summary": "Priya walked through the two vendor bids. The current vendor was cheaper over a year, so the renewal goes ahead. Marcus raised support response times as a risk."}"#

    var reply: String {
        get { lock.withLock { replyText } }
        set { lock.withLock { replyText = newValue } }
    }

    var chatBodies: [Data] { lock.withLock { bodies } }

    /// The transcripts sent to the model, in order.
    var sentTranscripts: [String] {
        chatBodies.compactMap { body in
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = object["messages"] as? [[String: Any]],
                  let user = messages.last?["content"] as? String else { return nil }
            return user
        }
    }

    func countTokens(_ text: String) async throws -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private var blocking = false
    /// While true, a chat waits until its task is cancelled (or this flips).
    var blockChat: Bool {
        get { lock.withLock { blocking } }
        set { lock.withLock { blocking = newValue } }
    }
    var onChatStarted: (@Sendable () -> Void)?

    func chat(body: Data) async throws -> String {
        let (fail, reply): (Bool, String) = lock.withLock {
            bodies.append(body)
            return (failChat, replyText)
        }
        onChatStarted?()
        while blockChat {
            try await Task.sleep(for: .milliseconds(2))
        }
        if fail { throw MeetingTitlesEngineError.requestFailed }
        return reply
    }
}

/// A virtual clock for the queue: `sleep` moves it, nothing reads the wall
/// clock. The tiny real pause only lets other tasks run.
final class TitlesTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 1_000

    var now: TimeInterval { lock.withLock { seconds } }

    func advance(_ duration: Duration) {
        lock.withLock { seconds += MeetingTitlesQueue.seconds(duration) }
    }

    func sleep(_ duration: Duration) async {
        advance(duration)
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Records starts and stops in order, with a shared event log so tests can
/// check what happened relative to other fakes.
final class FakeTitlesHost: MeetingTitlesEngineHost, @unchecked Sendable {
    let engine: FakeTitlesEngine
    private let lock = NSLock()
    private var log: [String] = []
    private var starts: [TimeInterval] = []
    var startFails = false
    /// When set, each start's virtual time is recorded in `startTimes`.
    var clock: TitlesTestClock?

    init(engine: FakeTitlesEngine = FakeTitlesEngine(), clock: TitlesTestClock? = nil) {
        self.engine = engine
        self.clock = clock
    }

    var events: [String] { lock.withLock { log } }
    var startCount: Int { events.filter { $0 == "start" }.count }
    var startTimes: [TimeInterval] { lock.withLock { starts } }

    func note(_ event: String) { lock.withLock { log.append(event) } }

    func start() async throws -> any MeetingTitlesEngine {
        note("start")
        if let now = clock?.now { lock.withLock { starts.append(now) } }
        if lock.withLock({ startFails }) { throw MeetingTitlesEngineError.helperMissing }
        return engine
    }

    func stop() async {
        note("stop")
    }
}

enum MeetingTitlesFixtures {
    static func temporaryDirectory(_ name: String = "meeting-titles") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A styled meeting with enough words to label. `extraFrontmatter` lines
    /// go after `title:`.
    static func meetingMarkdown(
        title: String = "Meeting with Priya",
        date: String = "2026-03-04",
        time: String = "10:05:00",
        extraFrontmatter: [String] = [],
        turns: [(String, String, String)] = defaultTurns
    ) -> String {
        let frontmatter = [
            "title: \"\(title)\"",
            "capture_id: \"\(UUID().uuidString)\"",
            "capture_type: meeting",
            "format_version: 1",
            "date: \(date)",
            "time: \(time)",
            "duration: \"12:30\"",
            "mic_utterances: 2",
            "system_utterances: 2",
        ] + extraFrontmatter + ["transcript_style: styled"]
        let body = turns.map { stamp, label, text in "**\(stamp)**  [\(label)]\n\(text)" }
            .joined(separator: "\n\n")
        return "---\n\(frontmatter.joined(separator: "\n"))\n---\n\n# \(title)\n\nRecorded today\n\n## Transcript\n\n\(body)\n"
    }

    /// A meeting already labeled at the current version from its own
    /// speakers, as the writer leaves it.
    static func labeledMeetingMarkdown(date: String = "2026-03-04") -> String {
        let raw = meetingMarkdown(date: date)
        let speakers = MeetingTitlesSpeakers.fingerprint(of: MeetingTitlesTranscript.turns(fromMeetingMarkdown: raw))
        return MeetingTitlesFrontmatterWriter.markdown(
            byApplying: MeetingTitlesLabel(title: nil, line: nil, summary: "Already labeled."),
            replaceableTitle: nil, speakers: speakers, to: raw
        ) ?? raw
    }

    static let defaultTurns: [(String, String, String)] = [
        ("00:01", "Mic/You", "Thanks for joining. I wanted to go over the two vendor bids before the contract runs out next month."),
        ("00:09", "System/Priya", "Sure. The current vendor came back about ten percent cheaper over a full year than the new one."),
        ("00:21", "System/Marcus", "Support response times were slow last quarter though, so that is the one risk I would flag."),
        ("00:33", "Mic/You", "Okay, so we renew with the current vendor for one year and watch support closely."),
    ]

    @discardableResult
    static func writeMeeting(_ markdown: String, named name: String, in directory: URL) -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

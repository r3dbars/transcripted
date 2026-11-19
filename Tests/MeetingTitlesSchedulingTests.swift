import Foundation

/// When the titles queue may load the model: never while the app is busy,
/// cancelled the moment something starts, a quiet period before it loads
/// again, and a meeting's own speaker review answered first.
@MainActor
func testMeetingTitlesScheduling() async {
    await runSuite("A start signal cancels a running job at once, without waiting for a poll") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(title: "Meeting with Priya and Marcus"), named: "a.md", in: directory
        )
        let clock = TitlesTestClock()
        let engine = FakeTitlesEngine()
        engine.blockChat = true
        let host = FakeTitlesHost(engine: engine, clock: clock)
        let signals = SignalLog()
        // isBusy never turns true, so no poll can be what cancels the job.
        let queue = MeetingTitlesQueue(host: host, environment: .init(
            isEnabled: { true },
            isBusy: { false },
            sleep: { await clock.sleep($0) },
            now: { clock.now }
        ))
        engine.onChatStarted = { [weak queue] in
            Task { @MainActor in
                guard signals.firstChat() else { return }
                signals.signalledAt = clock.now
                queue?.noteBusyStarted()
                engine.blockChat = false
            }
        }
        var results: [MeetingTitlesJobResult] = []
        queue.onJobFinished = { _, result in results.append(result) }
        queue.enqueue(MeetingTitlesJob(transcriptURL: url, titleRule: .fromFile))
        await queue.waitUntilIdle()

        assertEqual(results, [.cancelled, .written])
        assertEqual(host.events, ["start", "stop", "start", "stop"], "the helper stops on the signal")
        assertEqual(host.startCount, 2)
        if let signalled = signals.signalledAt, let restarted = host.startTimes.last {
            assertTrue(restarted - signalled >= 45, "the helper waits out the quiet period, got \(restarted - signalled)")
        } else {
            assertTrue(false, "the signal fired and the job ran again")
        }
    }

    await runSuite("A burst of dictations doesn't load and kill the helper each time") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(date: "2026-03-05"), named: "a.md", in: directory)
        let second = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(date: "2026-03-04"), named: "b.md", in: directory)
        let clock = TitlesTestClock()
        let host = FakeTitlesHost(clock: clock)
        let start = clock.now
        // Three dictations 20 seconds apart, five seconds each.
        let bursts: [Range<TimeInterval>] = [0..<5, 20..<25, 40..<45].map { (start + $0.lowerBound)..<(start + $0.upperBound) }
        let queue = MeetingTitlesQueue(host: host, environment: .init(
            isEnabled: { true },
            isBusy: { bursts.contains { $0.contains(clock.now) } },
            sleep: { await clock.sleep($0) },
            now: { clock.now }
        ))
        queue.noteBusyStarted()
        queue.enqueueBackfill([
            MeetingTitlesJob(transcriptURL: first, titleRule: .appMade("Meeting with Priya")),
            MeetingTitlesJob(transcriptURL: second, titleRule: .appMade("Meeting with Priya")),
        ])
        await queue.waitUntilIdle()

        // The real helper returns the running child on a second start; the
        // fake counts calls, so check nothing stopped it in between.
        assertEqual(Array(host.events.drop(while: { $0 != "start" })), ["start", "start", "stop"], "one load for both meetings")
        assertTrue((host.startTimes.first ?? 0) >= start + 45 + 45, "45 quiet seconds after the last dictation")
        for url in [first, second] {
            assertEqual(TranscriptFrontmatter.values(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "")?["ai_summary_version"], "1")
        }
    }

    await runSuite("Meetings that never need the model don't wait for the quiet period") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let short = MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(turns: [("00:01", "Mic/You", "Testing one two.")]), named: "short.md", in: directory
        )
        let clock = TitlesTestClock()
        let host = FakeTitlesHost(clock: clock)
        let queue = MeetingTitlesQueue(host: host, environment: .init(
            isEnabled: { true }, isBusy: { false }, sleep: { await clock.sleep($0) }, now: { clock.now }
        ))
        queue.noteBusyStarted()
        queue.noteBusyChanged()
        var results: [MeetingTitlesJobResult] = []
        var activities: [MeetingTitlesQueue.Activity] = []
        queue.onJobFinished = { _, result in results.append(result) }
        queue.onActivityChange = { activities.append($0) }
        queue.enqueue(MeetingTitlesJob(transcriptURL: short, titleRule: .fromFile))
        await queue.waitUntilIdle()
        assertEqual(results, [.tooShort])
        assertEqual(host.startCount, 0)
        assertFalse(activities.contains(.waitingForBusy), "no quiet wait for a job that never loads the helper")
    }

    await runSuite("A meeting whose speaker review waits is held; others go first, and it runs once answered") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewing = MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(title: "Meeting at 10:05 AM", turns: unnamedTurns), named: "reviewing.md", in: directory
        )
        let other = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(), named: "other.md", in: directory)
        let clock = TitlesTestClock()
        let host = FakeTitlesHost(clock: clock)
        let review = ReviewState()
        let queue = MeetingTitlesQueue(host: host, environment: .init(
            isEnabled: { true },
            isBusy: { false },
            isAwaitingSpeakerReview: { url, _ in url.lastPathComponent == "reviewing.md" && review.pending },
            sleep: { interval in
                // The review is answered while the queue waits on it: the
                // speakers get their names in the file.
                if interval == .seconds(30), review.pending {
                    review.pending = false
                    let named = ((try? String(contentsOf: reviewing, encoding: .utf8)) ?? "")
                        .replacingOccurrences(of: "System/Speaker 1", with: "System/Dana")
                    try? named.write(to: reviewing, atomically: true, encoding: .utf8)
                }
                await clock.sleep(interval)
            },
            now: { clock.now }
        ))
        var order: [String] = []
        queue.onJobFinished = { job, result in order.append("\(job.transcriptURL.lastPathComponent):\(result)") }
        queue.enqueue(MeetingTitlesJob(transcriptURL: other, titleRule: .appMade("Meeting with Priya")))
        queue.enqueue(MeetingTitlesJob(transcriptURL: reviewing, titleRule: .appMade("Meeting at 10:05 AM")))
        await queue.waitUntilIdle()

        assertEqual(order, ["reviewing.md:awaitingSpeakerReview", "other.md:written", "reviewing.md:written"])
        let sent = host.engine.sentTranscripts.last ?? ""
        assertTrue(sent.contains("Dana:"), "the model read the names from the answered review")
        assertFalse(sent.contains("Unknown speaker"))
        let values = TranscriptFrontmatter.values(in: (try? String(contentsOf: reviewing, encoding: .utf8)) ?? "") ?? [:]
        assertEqual(values["ai_title"], "Vendor contract renewal", "the app's evidence from the save still counts")
    }

    await runSuite("A later save with no evidence keeps what the waiting job knew") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A calendar event's title that happens to read like the rule's.
        let url = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(title: "Meeting with Priya and Marcus"), named: "cal.md", in: directory)
        let review = ReviewState()
        let clock = TitlesTestClock()
        let queue = MeetingTitlesQueue(host: FakeTitlesHost(), environment: .init(
            isEnabled: { true },
            isBusy: { false },
            isAwaitingSpeakerReview: { _, _ in review.pending },
            sleep: { interval in
                if interval == .seconds(30) { review.pending = false }
                await clock.sleep(interval)
            },
            now: { clock.now }
        ))
        queue.enqueue(MeetingTitlesJob(transcriptURL: url, titleRule: .unknown))
        // The review's own save arrives with no evidence of its own.
        queue.enqueue(MeetingTitlesJob(transcriptURL: url, titleRule: .fromFile))
        await queue.waitUntilIdle()
        let values = TranscriptFrontmatter.values(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "") ?? [:]
        assertNil(values["ai_title"], "the recording's own title is kept")
        assertNotNil(values["ai_summary"])
    }
}

private let unnamedTurns: [(String, String, String)] = [
    ("00:01", "Mic/You", "Thanks for joining. I wanted to go over the two vendor bids before the contract runs out next month."),
    ("00:09", "System/Speaker 1", "Sure. The current vendor came back about ten percent cheaper over a full year than the new one."),
    ("00:21", "System/Speaker 1", "Support response times were slow last quarter though, so that is the one risk I would flag."),
    ("00:33", "Mic/You", "Okay, so we renew with the current vendor for one year and watch support closely."),
]

private final class ReviewState: @unchecked Sendable {
    private let lock = NSLock()
    private var isPending = true
    var pending: Bool {
        get { lock.withLock { isPending } }
        set { lock.withLock { isPending = newValue } }
    }
}

@MainActor
private final class SignalLog {
    private var chats = 0
    var signalledAt: TimeInterval?

    func firstChat() -> Bool {
        chats += 1
        return chats == 1
    }
}

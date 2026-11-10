import Combine
import Foundation

@MainActor
func testHomeMeetingRevealRequest() async {
    guard ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1" else {
        assertTrue(false, "Injected reveal model fixtures require the file logger to be disabled")
        return
    }

    await runSuite("A reveal requested before presentation survives initial hidden gating and loads when shown") {
        let fixture = HomeMeetingRevealFixture()
        defer { fixture.close() }
        let target = revealValueURL("before-show", 25)
        fixture.model.requestMeetingReveal(at: target, token: 1)
        fixture.model.setShown(false)
        assertEqual(fixture.loader.issuedCount, 0)
        fixture.model.setShown(true)
        let request = await fixture.loader.nextRequest()
        assertEqual(request.target, target)
        assertEqual(request.meetingLimit, 11)
        assertEqual(request.dictationLimit, 11)
        let mark = fixture.events.count
        fixture.loader.finish(request, snapshot: revealSnapshot("before-show", count: 26, minimum: 25))
        let rows = await fixture.events.next(after: mark)
        assertEqual(rows, revealRows("before-show", count: 25).map(\.transcriptURL))
        fixture.model.finishMeetingReveal(token: 1)
        fixture.model.refreshAfterCaptureArtifactsChanged()
        let sentinel = await fixture.loader.nextRequest()
        assertEqual(sentinel.target, nil)
        assertEqual(sentinel.meetingLimit, 26)
        assertEqual(fixture.loader.issuedCount, 2)
        await fixture.accept(sentinel, batch: "before-show-sentinel", count: 26)
    }

    await runSuite("A targeted load retains a manual window and commits its expansion before a reentrant finish") {
        let fixture = HomeMeetingRevealFixture()
        defer { fixture.close() }
        await fixture.showInitial()
        fixture.model.loadMoreMeetings()
        let manual = await fixture.loader.nextRequest()
        assertEqual(manual.meetingLimit, 21)
        await fixture.accept(manual, batch: "manual", count: 21)
        fixture.model.requestMeetingReveal(at: revealValueURL("target", 25), token: 20)
        let target = await fixture.loader.nextRequest()
        assertEqual(target.meetingLimit, 21, "a reveal must not reset an existing twenty-row window")
        let model = fixture.model
        fixture.events.onRows = { [weak model] rows in
            if rows.first?.lastPathComponent.hasPrefix("target-") == true {
                assertEqual(rows.count, 25)
                model?.finishMeetingReveal(token: 20)
            }
        }
        await fixture.accept(target, batch: "target", count: 26, minimum: 25)
        fixture.events.onRows = nil
        fixture.model.loadMoreMeetings()
        let nextManual = await fixture.loader.nextRequest()
        assertNil(nextManual.target)
        assertEqual(nextManual.meetingLimit, 36, "the reentrant finish must retain twenty-five visible rows before adding ten")
        await fixture.accept(nextManual, batch: "next-manual", count: 36)
    }

    await runSuite("Several reveal requests during one load coalesce to the latest target without stale enlargement") {
        let fixture = HomeMeetingRevealFixture()
        defer { fixture.close() }
        await fixture.showInitial()
        let a = revealValueURL("A", 25), b = revealValueURL("B", 25), c = revealValueURL("C", 15)
        fixture.model.requestMeetingReveal(at: a, token: 1)
        let first = await fixture.loader.nextRequest()
        fixture.model.requestMeetingReveal(at: b, token: 2)
        fixture.model.requestMeetingReveal(at: c, token: 3)
        fixture.loader.finish(first, snapshot: revealSnapshot("A", count: 26, minimum: 25))
        let latest = await fixture.loader.nextRequest()
        assertEqual(latest.target, c)
        assertEqual(latest.meetingLimit, 11, "the old target cannot enlarge the new request's window")
        assertEqual(fixture.loader.issuedCount, 3, "only initial, A, and the latest target may load")
        assertEqual(fixture.loader.maximumPending, 1)
        await fixture.accept(latest, batch: "C", count: 16, minimum: 15)
        assertTrue(fixture.events.rows(for: "A").allSatisfy { $0.count <= 10 })
    }

    await runSuite("An old expiry token cannot erase a newer reveal of the same transcript") {
        let fixture = HomeMeetingRevealFixture()
        defer { fixture.close() }
        await fixture.showInitial()
        let sameURL = revealValueURL("same", 25)
        fixture.model.requestMeetingReveal(at: sameURL, token: 100)
        let first = await fixture.loader.nextRequest()
        fixture.model.requestMeetingReveal(at: sameURL, token: 101)
        fixture.model.finishMeetingReveal(token: 100)
        fixture.loader.finish(first, snapshot: revealSnapshot("same", count: 26, minimum: 25))
        let newer = await fixture.loader.nextRequest()
        assertEqual(newer.target, sameURL)
        assertEqual(newer.meetingLimit, 11)
        assertTrue(fixture.events.rows(for: "same").allSatisfy { $0.count <= 10 })
        await fixture.accept(newer, batch: "same", count: 26, minimum: 25)
    }

    await runSuite("Finishing a current reveal before completion suppresses its extra rows and trailing target") {
        let fixture = HomeMeetingRevealFixture()
        defer { fixture.close() }
        await fixture.showInitial()
        fixture.model.requestMeetingReveal(at: revealValueURL("expired", 25), token: 4)
        let expired = await fixture.loader.nextRequest()
        fixture.model.finishMeetingReveal(token: 4)
        fixture.model.refreshAfterCaptureArtifactsChanged()
        fixture.loader.finish(expired, snapshot: revealSnapshot("expired", count: 26, minimum: 25))
        let sentinel = await fixture.loader.nextRequest()
        assertNil(sentinel.target)
        assertEqual(sentinel.meetingLimit, 11)
        await fixture.accept(sentinel, batch: "after-expiry", count: 11)
        assertTrue(fixture.events.rows(for: "expired").allSatisfy { $0.count <= 10 })
    }

    await runSuite("Hiding or cancelling invalidates an old target while an explicit new reveal still works") {
        for hide in [true, false] {
            let fixture = HomeMeetingRevealFixture()
            defer { fixture.close() }
            await fixture.showInitial()
            fixture.model.requestMeetingReveal(at: revealValueURL("abandoned", 25), token: 8)
            let abandoned = await fixture.loader.nextRequest()
            if hide { fixture.model.setShown(false) } else { fixture.model.cancel() }
            fixture.loader.finish(abandoned, snapshot: revealSnapshot("abandoned", count: 26, minimum: 25))
            fixture.model.refreshAfterCaptureArtifactsChanged()
            fixture.model.setShown(true)
            let ordinary = await fixture.loader.nextRequest()
            assertNil(ordinary.target, "hide and cancel must clear the old target intent")
            assertEqual(ordinary.meetingLimit, 11)
            await fixture.accept(ordinary, batch: "after-abandonment", count: 11)
            fixture.model.setShown(false)
            let newURL = revealValueURL("explicit-new", 15)
            fixture.model.requestMeetingReveal(at: newURL, token: 9)
            fixture.model.setShown(false)
            fixture.model.setShown(true)
            let newRequest = await fixture.loader.nextRequest()
            assertEqual(newRequest.target, newURL)
            assertEqual(newRequest.meetingLimit, 11)
            await fixture.accept(newRequest, batch: "explicit-new", count: 16, minimum: 15)
            assertTrue(fixture.events.rows(for: "abandoned").allSatisfy { $0.count <= 10 })
        }
    }

    await runSuite("A missing target stays bounded across an explicit artifact refresh") {
        let fixture = HomeMeetingRevealFixture()
        defer { fixture.close() }
        await fixture.showInitial()
        let missing = revealValueURL("not-in-snapshot", 1)
        fixture.model.requestMeetingReveal(at: missing, token: 50)
        let request = await fixture.loader.nextRequest()
        await fixture.accept(request, batch: "missing", count: 11)
        fixture.model.refreshAfterCaptureArtifactsChanged()
        let sentinel = await fixture.loader.nextRequest()
        assertEqual(sentinel.target, missing, "an explicit artifact refresh may retain the unfinished intent")
        assertEqual(sentinel.meetingLimit, 11, "a missing match must not page through older rows")
        assertEqual(fixture.loader.issuedCount, 3)
        fixture.model.finishMeetingReveal(token: 50)
        await fixture.accept(sentinel, batch: "missing-sentinel", count: 11)
    }
}

private func revealValueURL(_ batch: String, _ ordinal: Int) -> URL {
    URL(fileURLWithPath: "/synthetic-meeting-reveal/\(batch)-\(ordinal).md")
}

private func revealRows(_ batch: String, count: Int) -> [RecentMeetingItem] {
    guard count > 0 else { return [] }
    return (1...count).map { ordinal in
        RecentMeetingItem(title: "Synthetic \(batch) \(ordinal)",
                          date: Date(timeIntervalSince1970: 1_700_000_000 - Double(ordinal)),
                          startDate: nil, endDate: nil, transcriptURL: revealValueURL(batch, ordinal),
                          audio: nil, speakerStatus: .ready)
    }
}

private func revealSnapshot(_ batch: String, count: Int, minimum: Int? = nil) -> RecentCaptureSnapshot {
    RecentCaptureSnapshot(meetings: count == 0 ? [] : revealRows(batch, count: count), dictations: [],
                          dictationCounts: .init(total: 0, today: 0, totalWords: 0),
                          meetingRevealMinimumCount: minimum)
}

@MainActor
private final class HomeMeetingRevealFixture {
    let loader: HomeMeetingRevealLoaderGate
    let events: HomeMeetingRevealEvents
    let model: HomeViewModel
    private var subscription: AnyCancellable?

    init() {
        let loader = HomeMeetingRevealLoaderGate()
        let events = HomeMeetingRevealEvents()
        let model = HomeViewModel(snapshotLoader: { d, m, target in await loader.load(d, m, target) },
                                  activationTracker: { _, _, _, _ in false }, notificationCenter: NotificationCenter())
        self.loader = loader
        self.events = events
        self.model = model
        subscription = model.$meetingDaySections.dropFirst().sink { [weak events] sections in
            events?.record(sections.flatMap(\.items).map(\.transcriptURL))
        }
    }

    func showInitial() async {
        model.setShown(true)
        model.refresh()
        let request = await loader.nextRequest()
        assertNil(request.target)
        assertEqual(request.meetingLimit, 11)
        await accept(request, batch: "initial", count: 11)
    }

    func accept(_ request: HomeMeetingRevealLoaderGate.Request, batch: String, count: Int, minimum: Int? = nil) async {
        let mark = events.count
        loader.finish(request, snapshot: revealSnapshot(batch, count: count, minimum: minimum))
        let rows = await events.next(after: mark)
        assertEqual(rows, revealRows(batch, count: max(0, count - 1)).map(\.transcriptURL),
                    "the accepted fixture snapshot keeps its visible prefix and drops one lookahead row")
    }

    func close() {
        subscription?.cancel()
        events.onRows = nil
        model.cancel()
        loader.close()
    }
}

@MainActor
private final class HomeMeetingRevealLoaderGate {
    struct Request: Sendable {
        let id: Int
        let dictationLimit: Int
        let meetingLimit: Int
        let target: URL?
    }
    private var queued: [Request] = []
    private var continuations: [Int: CheckedContinuation<RecentCaptureSnapshot, Never>] = [:]
    private var waiters: [CheckedContinuation<Request, Never>] = []
    private var closed = false
    private(set) var issuedCount = 0
    private(set) var maximumPending = 0

    func load(_ dictationLimit: Int, _ meetingLimit: Int, _ target: URL?) async -> RecentCaptureSnapshot {
        guard !closed else { return revealSnapshot("closed", count: 0) }
        return await withCheckedContinuation { continuation in
            issuedCount += 1
            let request = Request(id: issuedCount, dictationLimit: dictationLimit, meetingLimit: meetingLimit, target: target)
            continuations[request.id] = continuation
            maximumPending = max(maximumPending, continuations.count)
            if waiters.isEmpty { queued.append(request) } else { waiters.removeFirst().resume(returning: request) }
        }
    }

    func nextRequest() async -> Request {
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func finish(_ request: Request, snapshot: RecentCaptureSnapshot) {
        let continuation = continuations.removeValue(forKey: request.id)
        assertNotNil(continuation, "each controlled load must complete once")
        continuation?.resume(returning: snapshot)
    }

    func close() {
        closed = true
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending { continuation.resume(returning: revealSnapshot("closed", count: 0)) }
    }
}

@MainActor
private final class HomeMeetingRevealEvents {
    private var events: [[URL]] = []
    private var waiters: [(Int, CheckedContinuation<[URL], Never>)] = []
    var onRows: (([URL]) -> Void)?
    var count: Int { events.count }

    func record(_ rows: [URL]) {
        events.append(rows)
        onRows?(rows)
        let ready = waiters.filter { events.count > $0.0 }
        waiters.removeAll { events.count > $0.0 }
        for (index, continuation) in ready { continuation.resume(returning: events[index]) }
    }

    func next(after index: Int) async -> [URL] {
        if events.count > index { return events[index] }
        return await withCheckedContinuation { waiters.append((index, $0)) }
    }

    func rows(for batch: String) -> [[URL]] {
        events.filter { $0.first?.lastPathComponent.hasPrefix("\(batch)-") == true }
    }
}

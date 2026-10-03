import Foundation
import Testing
@testable import TranscriptedLiveCore

/// A clock the test moves by hand.
private final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        time += seconds
        lock.unlock()
    }
}

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func readSession(_ output: LiveOutput) throws -> LiveSession {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(LiveSession.self, from: Data(contentsOf: output.sessionURL))
}

@Suite struct IdleHeartbeatTests {
    @Test func anIdleHelperRewritesSessionJsonAboutEveryFourSeconds() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = VirtualClock()
        let output = try LiveOutput(root: root, model: "test", now: { clock.now })
        let first = try readSession(output).updatedAt

        var elapsed: TimeInterval = 0
        for step in [0.5, 0.5, 1, 1, 0.9] {  // 0.5, 1, 2, 3, 3.9 s
            clock.advance(step)
            elapsed += step
            try output.heartbeat()
            #expect(try readSession(output).updatedAt == first, "rewrote at \(elapsed) s")
        }
        clock.advance(0.1)  // 4 s
        try output.heartbeat()
        #expect(try readSession(output).updatedAt > first)
    }

    @Test func recordingUpdatesStillWriteFourTimesASecond() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = VirtualClock()
        let output = try LiveOutput(root: root, model: "test", now: { clock.now })
        let before = try readSession(output).updatedAt

        // session.json stores whole-second ISO 8601 dates, so a 0.25 s step can't
        // show in updatedAt; each update's partial landing on disk is the proof.
        clock.advance(0.25)
        try output.update(partials: ["them": "so the"], audioSeconds: 1)
        var session = try readSession(output)
        #expect(session.updatedAt >= before)
        #expect(session.partial == ["them": "so the"])

        clock.advance(0.25)
        try output.update(partials: ["them": "so the plan"], audioSeconds: 1.25)
        session = try readSession(output)
        #expect(session.partial == ["them": "so the plan"])
    }

    @Test func touchRefreshesUpdatedAtBeforeTheHeartbeatIsDue() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = VirtualClock()
        let output = try LiveOutput(root: root, model: "test", now: { clock.now })
        let before = try readSession(output).updatedAt

        clock.advance(1)  // heartbeat isn't due for another 3 s
        try output.touch()
        #expect(try readSession(output).updatedAt > before)
    }

    @Test func aClockThatJumpsBackStillGetsAHeartbeat() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = VirtualClock()
        let output = try LiveOutput(root: root, model: "test", now: { clock.now })
        let before = try readSession(output).updatedAt

        clock.advance(-60)
        try output.heartbeat()
        #expect(try readSession(output).updatedAt < before)
    }
}

// MARK: - Watch mode: models only while a meeting is live

/// Counts loads and how many loaded transcribers are still alive.
private final class LoadTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var loadCount = 0
    private var aliveCount = 0

    var loads: Int { lock.lock(); defer { lock.unlock() }; return loadCount }
    var loadedAndAlive: Int { lock.lock(); defer { lock.unlock() }; return aliveCount }

    func didLoad() { lock.lock(); loadCount += 1; aliveCount += 1; lock.unlock() }
    func didRelease() { lock.lock(); aliveCount -= 1; lock.unlock() }
}

private struct LoadFailed: Error {}

private actor FakeTranscriber: LiveTranscribing {
    nonisolated let speaker: String
    private let tracker: LoadTracker
    private let failsToLoad: Bool
    private let onLoad: @Sendable () -> Void
    private var isLoaded = false

    init(speaker: String, tracker: LoadTracker, failsToLoad: Bool = false, onLoad: @escaping @Sendable () -> Void = {}) {
        self.speaker = speaker
        self.tracker = tracker
        self.failsToLoad = failsToLoad
        self.onLoad = onLoad
    }

    deinit {
        if isLoaded { tracker.didRelease() }
    }

    func load() throws {
        if failsToLoad { throw LoadFailed() }
        isLoaded = true
        tracker.didLoad()
        onLoad()
    }

    func feed(_ samples: [Float], sampleRate: Double, startSeconds: Double) -> [LiveUtterance] { [] }

    func partialText() -> String { "" }

    func flush(atSeconds seconds: Double) -> [LiveUtterance] {
        let text = speaker == "you" ? "let me check the speaker review code first" : "does that sound good to you"
        return [LiveUtterance(t: 1, speaker: speaker, text: text)]
    }
}

/// Writes the journal Transcripted keeps next to a recording.
private func writeJournal(in directory: URL, meetingId: String, state: String) throws {
    let json = """
    {"state":"\(state)","startedAt":"2026-10-03T10:00:00Z","primaryMicFilename":null,"micSegments":[],"systemAudioFilename":null}
    """
    try Data(json.utf8).write(to: directory.appendingPathComponent(meetingId + RecordingLocator.journalSuffix))
}

@Suite struct WatchModelLifetimeTests {
    private func makeRunner(
        root: URL, tracker: LoadTracker, failsToLoad: Bool = false, onLoad: @escaping @Sendable () -> Void = {}
    ) throws -> LiveRunner {
        let output = try LiveOutput(root: root, model: "test", now: { Date() })
        return LiveRunner(output: output, log: { _ in }) { speaker in
            FakeTranscriber(speaker: speaker, tracker: tracker, failsToLoad: failsToLoad, onLoad: onLoad)
        }
    }

    @Test func modelsLoadForAMeetingAndAreReleasedOnceItEnds() async throws {
        let root = try tempDirectory()
        let recordings = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: recordings)
        }
        let tracker = LoadTracker()
        // Transcripted stops recording right as the helper picks the meeting up,
        // so the meeting ends at the helper's first journal check.
        let journal = recordings.appendingPathComponent("meeting_test" + RecordingLocator.journalSuffix)
        let runner = try makeRunner(root: root, tracker: tracker) {
            guard FileManager.default.fileExists(atPath: journal.path) else { return }
            try? writeJournal(in: recordings, meetingId: "meeting_test", state: "stopped")
        }

        // Startup loads both, as main.swift does; watch lets them go.
        try await runner.loadModels()
        #expect(tracker.loads == 2)

        var idleTicks = 0
        var loadedWhileIdle: [Int] = []
        var statesSeenIdle: [LiveSession.State] = []
        try await runner.watch(recordingsDirectory: recordings, pollSeconds: 0.01, idleSeconds: 0.01) {
            idleTicks += 1
            loadedWhileIdle.append(tracker.loadedAndAlive)
            statesSeenIdle.append((try? readSession(runner.output))?.state ?? .idle)
            switch idleTicks {
            case 5:
                #expect(tracker.loads == 2, "no loads while nothing records")
                try? writeJournal(in: recordings, meetingId: "meeting_test", state: "recording")
                return false
            case ..<5:
                return false
            default:
                // The meeting is over by the first idle tick after it: end the watch.
                return true
            }
        }

        #expect(tracker.loads == 4, "each speaker loads once for the meeting")
        #expect(loadedWhileIdle.allSatisfy { $0 == 0 })
        #expect(statesSeenIdle.last == .ended)
        #expect(!statesSeenIdle.contains(.recording), "never asked to exit mid-meeting")

        let session = try readSession(runner.output)
        #expect(session.state == .ended)
        #expect(session.meetingId == "meeting_test")
        let lines = try String(contentsOfFile: try #require(session.utterancesPath), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines.contains { $0.contains("does that sound good to you") })
        #expect(lines.contains { $0.contains("let me check the speaker review code first") })
    }

    @Test func aModelThatFailsToLoadAtMeetingStartEndsTheWatchAndLeavesTheSessionIdle() async throws {
        let root = try tempDirectory()
        let recordings = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: recordings)
        }
        let tracker = LoadTracker()
        let runner = try makeRunner(root: root, tracker: tracker, failsToLoad: true)
        try writeJournal(in: recordings, meetingId: "meeting_test", state: "recording")

        await #expect(throws: LoadFailed.self) {
            try await runner.watch(recordingsDirectory: recordings, pollSeconds: 0.01, idleSeconds: 0.01) { false }
        }
        #expect(try readSession(runner.output).state == .idle)
    }
}

// MARK: - Orphan exit

@Suite struct OrphanExitTests {
    @Test func theHelperStopsOnlyWhenItsRealParentIsGoneAndTheModAskedForThat() {
        #expect(LiveRunner.parentIsGone(launchParent: 500, currentParent: 1, isEnabled: true))
        #expect(!LiveRunner.parentIsGone(launchParent: 500, currentParent: 500, isEnabled: true))
        // Started by launchd, or by hand without the mod's env var: today's behavior.
        #expect(!LiveRunner.parentIsGone(launchParent: 1, currentParent: 1, isEnabled: true))
        #expect(!LiveRunner.parentIsGone(launchParent: 500, currentParent: 1, isEnabled: false))
    }

    @Test func anIdleWatchReturnsWhenTheParentIsGoneAndShutdownClearsThePid() async throws {
        let root = try tempDirectory()
        let recordings = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: recordings)
        }
        let tracker = LoadTracker()
        let output = try LiveOutput(root: root, model: "test", now: { Date() })
        let runner = LiveRunner(output: output, log: { _ in }) { speaker in
            FakeTranscriber(speaker: speaker, tracker: tracker)
        }

        var currentParent: Int32 = 500
        var ticks = 0
        try await runner.watch(recordingsDirectory: recordings, pollSeconds: 0.01, idleSeconds: 0.01) {
            ticks += 1
            if ticks == 3 { currentParent = 1 }
            return LiveRunner.parentIsGone(launchParent: 500, currentParent: currentParent, isEnabled: true)
        }
        #expect(ticks == 3)
        output.shutdown()
        let session = try readSession(output)
        #expect(session.pid == 0)
        #expect(session.state == .idle)
    }
}

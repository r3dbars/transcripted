import TranscriptedWritingCore
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

@Suite("Scaffold prewarmer")
struct ScaffoldPrewarmerTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 100
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        var succeed = true
        var count: Int { lock.withLock { requests.count } }
        var prompts: [String] {
            lock.withLock {
                requests.compactMap { request in
                    guard let body = request.httpBody,
                          let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                    else { return nil }
                    return json["prompt"] as? String
                }
            }
        }
        var lastBody: [String: Any]? {
            lock.withLock {
                guard let body = requests.last?.httpBody else { return nil }
                return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
        }
        var lastPath: String? { lock.withLock { requests.last?.url?.path } }
        func perform(_ request: URLRequest) async -> Bool {
            lock.withLock { requests.append(request) }
            return succeed
        }
    }

    private func make(clock: Clock, recorder: Recorder) -> ScaffoldPrewarmer {
        ScaffoldPrewarmer(
            baseURL: URL(string: "http://127.0.0.1:17891")!,
            quietPeriod: 2,
            now: { clock.now },
            perform: recorder.perform
        )
    }

    @Test("A ready helper warms the frontmost app's scaffold with a one-token cached request")
    func readyWarmsCurrentRegister() async throws {
        let clock = Clock(), recorder = Recorder()
        let prewarmer = make(clock: clock, recorder: recorder)
        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.mail")
        #expect(recorder.count == 0)

        prewarmer.noteHelperReady()
        await prewarmer.settle()

        #expect(recorder.prompts == [RawContinuationPrompt.scaffold(for: .email)])
        let body = try #require(recorder.lastBody)
        #expect(body["n_predict"] as? Int == 1)
        #expect(body["cache_prompt"] as? Bool == true)
        #expect(body["stream"] as? Bool == false)
        #expect(recorder.lastPath == "/completion")
    }

    @Test("Switching to an app with the same register does not warm again")
    func sameRegisterIsNotRewarmed() async {
        let clock = Clock(), recorder = Recorder()
        let prewarmer = make(clock: clock, recorder: recorder)
        prewarmer.noteHelperReady()
        prewarmer.noteFrontmostApp(bundleIdentifier: "com.tinyspeck.slackmacgap")
        await prewarmer.settle()
        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.MobileSMS")
        await prewarmer.settle()
        #expect(recorder.count == 1)

        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.TextEdit")
        await prewarmer.settle()
        #expect(recorder.prompts.last == RawContinuationPrompt.scaffold(for: .prose))
        #expect(recorder.count == 2)
    }

    @Test("A recent completion holds warm-ups until the quiet period has passed")
    func quietPeriodGatesWarmups() async {
        let clock = Clock(), recorder = Recorder()
        let prewarmer = make(clock: clock, recorder: recorder)
        prewarmer.noteHelperReady()
        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.TextEdit")
        await prewarmer.settle()
        #expect(recorder.count == 1)

        prewarmer.noteCompletionActivity()
        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.mail")
        await prewarmer.settle()
        #expect(recorder.count == 1)

        clock.advance(2.5)
        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.mail")
        await prewarmer.settle()
        #expect(recorder.count == 2)
    }

    @Test("A completion keeps the warm register, so switching within the same register does not re-warm")
    func completionKeepsWarmedRegister() async {
        let clock = Clock(), recorder = Recorder()
        let prewarmer = make(clock: clock, recorder: recorder)
        prewarmer.noteHelperReady()
        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.TextEdit")
        await prewarmer.settle()
        prewarmer.noteCompletionActivity()
        clock.advance(3)
        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.Notes")
        await prewarmer.settle()
        #expect(recorder.count == 1)
        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.mail")
        await prewarmer.settle()
        #expect(recorder.count == 2)
    }

    @Test("Nothing is warmed while the helper is unavailable, and a fresh helper warms again")
    func unavailableHelperNeverWarms() async {
        let clock = Clock(), recorder = Recorder()
        let prewarmer = make(clock: clock, recorder: recorder)
        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.TextEdit")
        await prewarmer.settle()
        #expect(recorder.count == 0)

        prewarmer.noteHelperReady()
        await prewarmer.settle()
        #expect(recorder.count == 1)
        prewarmer.noteHelperUnavailable()
        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.mail")
        await prewarmer.settle()
        #expect(recorder.count == 1)

        prewarmer.noteHelperReady()
        await prewarmer.settle()
        #expect(recorder.count == 2)
    }

    @Test("A failed warm-up is retried on the next opportunity")
    func failureIsRetried() async {
        let clock = Clock(), recorder = Recorder()
        recorder.succeed = false
        let prewarmer = make(clock: clock, recorder: recorder)
        prewarmer.noteHelperReady()
        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.TextEdit")
        await prewarmer.settle()
        #expect(recorder.count == 1)
        recorder.succeed = true
        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.TextEdit")
        await prewarmer.settle()
        #expect(recorder.count == 2)
        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.TextEdit")
        await prewarmer.settle()
        #expect(recorder.count == 2)
    }
}

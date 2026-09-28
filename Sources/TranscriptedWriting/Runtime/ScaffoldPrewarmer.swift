#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Keeps the current register's scaffold in the helper's prompt cache.
///
/// Every prompt opens with a fixed scaffold of 70–180 tokens chosen by the
/// host app's register. The helper reuses whatever prefix its single slot
/// already holds, so after launch, after a helper restart, and after every
/// app switch that changes register, the first suggestion paid a cold
/// prefill of the whole scaffold — precisely the requests that set p99.
/// Prefilling the bare scaffold ahead of time, while the writer is not
/// typing, leaves only the scene block and field text for the real request.
///
/// Deliberately conservative: one slot means a warm-up that overlaps a real
/// request queues ahead of it, so warm-ups fire only when the helper is
/// ready, only when no completion has run for `quietPeriod`, only when the
/// register actually changed, and at most one at a time. A single decoded
/// token is requested because a zero-token request is not a documented
/// prefill-only contract on every helper build; the answer is discarded.
final class ScaffoldPrewarmer: @unchecked Sendable {
    typealias Perform = @Sendable (URLRequest) async -> Bool

    private let baseURL: URL
    private let quietPeriod: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let perform: Perform
    private let lock = NSLock()
    private var helperReady = false
    private var currentRegister: ContinuationRegister?
    private var warmedRegister: ContinuationRegister?
    private var lastCompletionAt: TimeInterval = -.greatestFiniteMagnitude
    private var inflight: Task<Void, Never>?

    init(
        baseURL: URL,
        quietPeriod: TimeInterval = 2.0,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        perform: Perform? = nil
    ) {
        self.baseURL = baseURL
        self.quietPeriod = quietPeriod
        self.now = now
        self.perform = perform ?? Self.performOverLoopback
    }

    /// A helper just became ready. Its cache is empty whatever was warmed
    /// before, so the current register is warmed again.
    func noteHelperReady() {
        lock.withLock {
            helperReady = true
            warmedRegister = nil
        }
        warmIfNeeded()
    }

    func noteHelperUnavailable() {
        let task: Task<Void, Never>? = lock.withLock {
            helperReady = false
            warmedRegister = nil
            defer { inflight = nil }
            return inflight
        }
        task?.cancel()
    }

    /// The frontmost app changed. Its register decides which scaffold the
    /// next real request will need.
    func noteFrontmostApp(bundleIdentifier: String?) {
        lock.withLock {
            currentRegister = ContinuationRegister.from(bundleIdentifier: bundleIdentifier)
        }
        warmIfNeeded()
    }

    /// A real completion is running. It owns the slot now. Its prompt opens
    /// with the scaffold of its own register, so whatever was warm before
    /// stays a fair guess: when the writer comes back to an app of the same
    /// register the prefix is still cached, and a different register warms
    /// on the switch as usual. Clearing the guess here made the prewarm fire
    /// after every app switch that followed a completion (56 times in the
    /// first live hour) for no gain.
    func noteCompletionActivity() {
        let task: Task<Void, Never>? = lock.withLock {
            lastCompletionAt = now()
            defer { inflight = nil }
            return inflight
        }
        task?.cancel()
    }

    /// Awaits any in-flight warm-up; tests only.
    func settle() async {
        let task = lock.withLock { inflight }
        await task?.value
    }

    private func warmIfNeeded() {
        let planned: (register: ContinuationRegister, request: URLRequest)? = lock.withLock {
            guard helperReady,
                  inflight == nil,
                  let register = currentRegister,
                  register != warmedRegister,
                  now() - lastCompletionAt >= quietPeriod
            else { return nil }
            guard let request = try? warmRequest(for: register) else { return nil }
            return (register, request)
        }
        guard let planned else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            let succeeded = await self.perform(planned.request)
            guard !Task.isCancelled else { return }
            self.lock.withLock {
                if succeeded, self.helperReady { self.warmedRegister = planned.register }
                self.inflight = nil
            }
            DiagnosticsLog.shared.record(
                "scaffold-prewarm",
                metadata: ["outcome": succeeded ? "warmed" : "failed"]
            )
        }
        let raced = lock.withLock { () -> Bool in
            guard inflight == nil else { return true }
            inflight = task
            return false
        }
        if raced { task.cancel() }
    }

    private func warmRequest(for register: ContinuationRegister) throws -> URLRequest {
        let body: [String: Any] = [
            "prompt": RawContinuationPrompt.scaffold(for: register),
            "n_predict": 1,
            "temperature": 0,
            "cache_prompt": true,
            "stream": false,
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("completion"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 5
        return request
    }

    private static func performOverLoopback(_ request: URLRequest) async -> Bool {
        guard let (_, response) = try? await LocalhostURLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}

import Foundation
import Security

enum LlamaRuntimeSnapshot: Equatable, Sendable {
    enum FailureReason: Equatable, Sendable {
        case assetsMissing, portInUse, launchFailed, healthTimeout, processExited, completionFailed

        fileprivate var menuDescription: String {
            switch self {
            case .assetsMissing: "Engine files missing — reinstall Tilde"
            case .portInUse: "Engine port busy"
            case .launchFailed: "Engine couldn't start"
            case .healthTimeout: "Engine didn't become ready"
            case .processExited: "Engine stopped"
            case .completionFailed: "Engine stopped responding"
            }
        }
    }

    case starting, ready
    case retrying(FailureReason), failed(FailureReason)

    var menuLine: String {
        menuLine(modelName: "Gemma")
    }

    func menuLine(modelName: String) -> String {
        switch self {
        case .starting: "Engine: \(modelName) (starting…)"
        case .ready: "Engine: \(modelName) (ready)"
        case let .retrying(reason): "⚠️ \(reason.menuDescription) — retrying"
        case let .failed(reason): "⚠️ \(reason.menuDescription)"
        }
    }

    var restartReasonAfterExit: FailureReason {
        if case let .retrying(reason) = self { return reason }
        return .processExited
    }

    var wasHealthyBeforeExit: Bool {
        self == .ready || self == .retrying(.completionFailed)
    }
}

/// Owns the app's one llama-server child, health state, and restart policy.
final class LlamaServerProcessHost: @unchecked Sendable {
    let port: Int

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var snapshot: LlamaRuntimeSnapshot { lifecycle.sync { runtimeSnapshot } }

    struct Assets: Sendable {
        let binary: String
        let model: String
        let modelInput: FileHandle?

        init(binary: String, model: String, modelInput: FileHandle? = nil) {
            self.binary = binary
            self.model = model
            self.modelInput = modelInput
        }
    }

    private let lifecycle = DispatchQueue(label: "com.justinbetker.draft.llama-lifecycle")
    private let preparation = DispatchQueue(label: "com.justinbetker.draft.llama-preparation", qos: .utility)
    private let assetResolver: @Sendable () -> Assets?
    private var process: Process?
    private var healthTask: Task<Void, Never>?
    private var runtimeSnapshot = LlamaRuntimeSnapshot.starting
    private var stopped = false
    private var preparing = false
    private var launchedAt = Date.distantPast
    private var restartPolicy = LlamaRestartPolicy()
    private var readinessObserver: (@Sendable (Bool) -> Void)?

    init(
        port: Int,
        modelFileProvider: @escaping @Sendable () -> VerifiedModelFile? = { nil },
        assetResolver: (@Sendable () -> Assets?)? = nil
    ) {
        precondition((1...65_535).contains(port))
        self.port = port
        self.assetResolver = assetResolver ?? {
            Self.resolveAssets(modelFileProvider: modelFileProvider)
        }
    }

    func start() {
        lifecycle.async { [weak self] in
            guard let self else { return }
            stopped = false
            prepareLaunch()
        }
    }

    /// Called with `true` each time a helper becomes ready to serve and
    /// `false` when that helper goes away. A fresh helper has an empty
    /// prompt cache, which is what the scaffold prewarmer needs to know.
    func setReadinessObserver(_ observer: (@Sendable (Bool) -> Void)?) {
        lifecycle.async { [weak self] in self?.readinessObserver = observer }
    }

    func stop() {
        let child: Process? = lifecycle.sync {
            stopped = true
            preparing = false
            healthTask?.cancel()
            healthTask = nil
            defer { process = nil }
            return process
        }
        Self.shutDownNow(child)
    }

    /// A transport/protocol failure means the owned helper is not serving a
    /// usable model. Concurrent failures see the cleared health bit and stop.
    func reportCompletionFailure() {
        lifecycle.async { [weak self] in
            guard let self, runtimeSnapshot == .ready, let process else { return }
            runtimeSnapshot = .retrying(.completionFailed)
            Self.requestShutdown(process)
        }
    }

    /// Recheck ownership immediately before a completion request. Cached
    /// health alone cannot prove the current listener is still our child.
    func isReadyForCompletion() async -> Bool {
        guard let child = lifecycle.sync(execute: { runtimeSnapshot == .ready ? process : nil }) else {
            return false
        }
        let ownsListener = await Task.detached(priority: .userInitiated) {
            Self.listenerBelongs(to: child, port: self.port)
        }.value
        return ownsListener && lifecycle.sync {
            runtimeSnapshot == .ready && process === child && !stopped
        }
    }

    /// The executable remains nested inside the signed app. The model is
    /// supplied only after ModelManager has verified the external bytes.
    private static func resolveAssets(modelFileProvider: @Sendable () -> VerifiedModelFile?) -> Assets? {
        let binary = Bundle.main.bundlePath + "/Contents/Helpers/llama-server"
        guard validCurrentBundleSeal(),
              FileManager.default.isExecutableFile(atPath: binary),
              let model = modelFileProvider() else { return nil }
        return Assets(binary: binary, model: "/dev/fd/0", modelInput: model.handle)
    }

    private static func validCurrentBundleSeal() -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        )
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    private func prepareLaunch() {
        guard !stopped, process == nil, !preparing else { return }
        preparing = true
        preparation.async { [weak self] in
            guard let self else { return }
            let assets = self.assetResolver()
            let ready = assets.map { Self.preparePort(for: $0.binary, port: self.port) } ?? false
            self.lifecycle.async { [weak self] in
                self?.finishPreparation(assets, ready: ready)
            }
        }
    }

    private func finishPreparation(_ assets: Assets?, ready: Bool) {
        preparing = false
        guard !stopped, process == nil else { return }
        guard let assets else {
            runtimeSnapshot = .failed(.assetsMissing)
            DiagnosticsLog.shared.record("llama-server-unavailable", metadata: ["reason": "assets-missing"])
            return
        }
        guard ready else {
            DiagnosticsLog.shared.record("llama-server-unavailable", metadata: ["reason": "port-in-use"])
            scheduleRestart(reason: .portInUse, wasHealthy: false, uptime: 0)
            return
        }
        launchPrepared(assets)
    }

    /// Runs only on `lifecycle`, so stop/restart cannot race child creation.
    /// The child is published only after Process.run() succeeds.
    private func launchPrepared(_ assets: Assets) {
        guard !stopped, process == nil else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: assets.binary)
        child.arguments = [
            "-m", assets.model,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-c", "4096",
            "--swa-full",
            "--cache-reuse", "256",
        ]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        if let modelInput = assets.modelInput { child.standardInput = modelInput }
        child.terminationHandler = { [weak self, weak child] _ in
            guard let self, let child else { return }
            lifecycle.async { self.handleExit(child) }
        }
        do {
            try child.run()
        } catch {
            DiagnosticsLog.shared.record("llama-server-unavailable", metadata: ["reason": "launch-failed"])
            scheduleRestart(reason: .launchFailed, wasHealthy: false, uptime: 0)
            return
        }
        process = child
        runtimeSnapshot = .starting
        launchedAt = Date()
        DiagnosticsLog.shared.record("llama-server-start", metadata: [:])
        pollHealth(of: child)
    }

    private func handleExit(_ child: Process) {
        guard process === child else { return }
        let wasHealthy = runtimeSnapshot.wasHealthyBeforeExit
        let reason = runtimeSnapshot.restartReasonAfterExit
        let uptime = Date().timeIntervalSince(launchedAt)
        process = nil
        healthTask?.cancel()
        healthTask = nil
        let shouldRestart = !stopped
        DiagnosticsLog.shared.record("llama-server-exit", metadata: ["willRestart": String(shouldRestart)])
        if wasHealthy { readinessObserver?(false) }
        if shouldRestart { scheduleRestart(reason: reason, wasHealthy: wasHealthy, uptime: uptime) }
    }

    private func scheduleRestart(
        reason: LlamaRuntimeSnapshot.FailureReason, wasHealthy: Bool, uptime: TimeInterval
    ) {
        guard !stopped else { return }
        runtimeSnapshot = .retrying(reason)
        let delay = restartPolicy.delay(wasHealthy: wasHealthy, uptime: uptime)
        lifecycle.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.prepareLaunch()
        }
    }

    /// Readiness probes ran on a flat 2-second cadence, so a helper that was
    /// actually serving 300ms after launch was not discovered until the next
    /// tick — up to ~1.7s of pure waiting added to the first suggestion after
    /// every launch, wake, or helper restart. That first suggestion is by
    /// definition a p99 sample, and usually the worst one the owner ever sees.
    /// Probe fast while a healthy start is still plausible, then settle back
    /// to the original 2s cadence for the long tail of a genuinely stuck
    /// helper.
    ///
    /// The attempt count is set so the ceiling to `health-timeout` matches the
    /// flat loop this replaced. That budget is *not* just the sleeps: each
    /// attempt also runs `probeHealth`, which can itself block for its own
    /// 2-second request timeout against a helper that accepts the connection
    /// but never answers. The old loop was 45 x (2s probe + 2s sleep) = 180s
    /// worst case; 51 attempts on this ladder is 179.4s. Counting only the
    /// sleeps would have quietly stretched the timeout by ~27 seconds, which
    /// is how long the menu would keep saying "starting" for a helper that is
    /// actually wedged.
    static let healthProbeAttempts = 51

    static func healthProbeDelayMilliseconds(attempt: Int) -> Int {
        switch attempt {
        case ..<4: return 100
        case ..<8: return 250
        case ..<12: return 500
        case ..<16: return 1_000
        default: return 2_000
        }
    }

    private func pollHealth(of child: Process) {
        healthTask?.cancel()
        let task = Task { [weak self, weak child] in
            guard let self, let child else { return }
            for attempt in 0..<Self.healthProbeAttempts {
                guard !Task.isCancelled, self.isCurrent(child) else { return }
                if await self.probeHealth(of: child) {
                    let observer = self.lifecycle.sync { () -> (@Sendable (Bool) -> Void)?? in
                        guard !self.stopped, self.runtimeSnapshot == .starting,
                              self.process === child else { return nil }
                        self.runtimeSnapshot = .ready
                        return .some(self.readinessObserver)
                    }
                    if let observer {
                        DiagnosticsLog.shared.record("llama-server-healthy", metadata: [:])
                        observer?(true)
                    }
                    return
                }
                try? await Task.sleep(
                    for: .milliseconds(Self.healthProbeDelayMilliseconds(attempt: attempt))
                )
            }
            guard self.isCurrent(child) else { return }
            let timedOut = self.lifecycle.sync { () -> Bool in
                guard !self.stopped, self.process === child else { return false }
                self.runtimeSnapshot = .retrying(.healthTimeout)
                return true
            }
            guard timedOut else { return }
            DiagnosticsLog.shared.record("llama-server-unavailable", metadata: ["reason": "health-timeout"])
            Self.requestShutdown(child)
        }
        healthTask = task
    }

    private func isCurrent(_ child: Process) -> Bool {
        lifecycle.sync { !stopped && process === child }
    }

    private func probeHealth(of child: Process) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = 2
        guard let (data, response) = try? await LocalhostURLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              String(data: data, encoding: .utf8)?.contains("ok") == true else { return false }
        let owns = await Task.detached(priority: .utility) {
            Self.listenerBelongs(to: child, port: self.port)
        }.value
        if !owns, child.isRunning {
            // `/health` answered but the child shows no listening socket on our
            // port. The likeliest cause is the kernel refusing the libproc
            // lookup across the process boundary (App Sandbox or hardened
            // runtime) — which the unit test cannot reach, since it can only
            // inspect itself, and which would otherwise gate every completion
            // to `.unavailable` with no visible cause anywhere.
            DiagnosticsLog.shared.record("llama-server-unowned-listener", metadata: [:])
        }
        return owns
    }

    /// Recheck runs before every completion request, so it has to be cheap.
    /// This used to shell out to `lsof -a -p <pid> -iTCP:<port> -sTCP:LISTEN`,
    /// which cost a fork/exec plus a `DispatchSemaphore` wait on a cooperative
    /// pool thread — the first thing inside the measured `ghost-request-timing`
    /// span, and up to 1.4 seconds of it on the TERM-to-KILL path in `command`.
    /// libproc answers the identical question straight from the kernel.
    ///
    /// The check itself is unchanged and still per-request: cached health alone
    /// cannot prove the current listener is still our child, so nothing here is
    /// cached or given a staleness window — it just stops costing a subprocess.
    private static func listenerBelongs(to child: Process, port: Int) -> Bool {
        guard child.isRunning else { return false }
        return holdsListeningSocket(pid: child.processIdentifier, port: port)
    }

    /// True when `pid` holds a TCP socket in LISTEN on `port`.
    ///
    /// Fail-closed in every direction: a libproc error, a short read, a
    /// descriptor that cannot be inspected, or a socket that is not
    /// listening TCP all answer "no", exactly as an `lsof` failure did.
    static func holdsListeningSocket(pid: pid_t, port: Int) -> Bool {
        let entrySize = MemoryLayout<proc_fdinfo>.stride
        let sized = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sized > 0 else { return false }

        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(sized) / entrySize)
        guard !descriptors.isEmpty else { return false }
        // Bytes actually allocated, not the kernel's sizing answer: the count
        // above truncates, so `sized` can exceed the buffer and overrun it.
        let capacity = Int32(descriptors.count * entrySize)
        let written = descriptors.withUnsafeMutableBufferPointer { buffer -> Int32 in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, capacity)
        }
        guard written > 0 else { return false }

        // `sizeof` in C includes trailing padding, so this must be `.stride`.
        // `.size` can be smaller; the kernel rejects a short buffer, every
        // descriptor would be skipped, and the gate would answer "no" forever.
        let wanted = Int32(MemoryLayout<socket_fdinfo>.stride)
        let usable = min(descriptors.count, Int(written) / entrySize)
        for index in 0..<usable
        where descriptors[index].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(
                pid, descriptors[index].proc_fd, PROC_PIDFDSOCKETINFO, &info, wanted
            ) == wanted else { continue }
            guard info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // libproc reports ports in network byte order.
            let listening = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if Int(listening) == port { return true }
        }
        return false
    }

    /// Reap only a re-parented helper from this exact app asset. Any other
    /// listener is left untouched and keeps this runtime unavailable.
    private static func preparePort(for binary: String, port: Int) -> Bool {
        guard let output = command(
            "/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        ) else { return false }
        let listeners = output.split(whereSeparator: \Character.isNewline).compactMap { Int32($0) }
        guard !listeners.isEmpty else { return true }
        guard listeners.count == 1,
              let pid = listeners.first,
              processPath(pid: pid) == URL(fileURLWithPath: binary).standardizedFileURL.path,
              command("/bin/ps", ["-o", "ppid=", "-p", String(pid)])?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "1" else { return false }
        kill(pid, SIGTERM)
        usleep(200_000)
        guard let remaining = command(
            "/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        ) else { return false }
        return remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func processPath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL.path
    }

    /// Shell probes are never run on the main thread and are fail-closed on a
    /// short deadline. A stuck probe is terminated, then killed if necessary.
    private static func command(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 1
    ) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do { try task.run() } catch { return nil }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            if exited.wait(timeout: .now() + 0.2) == .timedOut {
                kill(task.processIdentifier, SIGKILL)
                guard exited.wait(timeout: .now() + 0.2) == .success else { return nil }
            }
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    /// Runtime failures shut down away from the lifecycle queue. Clean app
    /// termination calls `shutDownNow` directly so the child cannot be orphaned.
    private static func requestShutdown(_ child: Process?) {
        guard let child else { return }
        DispatchQueue.global(qos: .utility).async {
            shutDownNow(child)
        }
    }

    /// Bounded TERM-to-KILL shutdown of this exact `Process`. The maximum wait
    /// is 1.2 seconds, including the post-KILL reap window.
    static func shutDownNow(_ child: Process?) {
        guard let child, child.isRunning else { return }
        child.terminate()
        waitForExit(child, timeout: 1)
        guard child.isRunning else { return }
        kill(child.processIdentifier, SIGKILL)
        waitForExit(child, timeout: 0.2)
    }

    private static func waitForExit(_ child: Process, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while child.isRunning, Date() < deadline { usleep(20_000) }
    }
}

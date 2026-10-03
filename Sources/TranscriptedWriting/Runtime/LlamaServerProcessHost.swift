#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation
import Security

enum LlamaRuntimeSnapshot: Equatable, Sendable {
    enum FailureReason: Equatable, Sendable {
        case assetsMissing, portInUse, launchFailed, healthTimeout, processExited, completionFailed

        fileprivate var menuDescription: String {
            switch self {
            case .assetsMissing: "Engine files missing — reinstall Transcripted"
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
    /// Rotated on every launch; every request to the helper carries it.
    let accessKey = LlamaServerAccessKey()
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
    /// Set only while a port-in-use retry is waiting on a listener the reap
    /// rule refused. Lifecycle queue only.
    private var blockedBy: BlockedPort?
    private let portListeners: @Sendable (Int) -> [Int32]?
    private let retryScheduler: (@Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void)?
    private let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory

    /// `portListeners` (default: `lsof`) and `retryScheduler` (default: a
    /// timer on the lifecycle queue) are seams for tests only.
    init(
        port: Int,
        modelFileProvider: @escaping @Sendable () -> VerifiedModelFile? = { nil },
        assetResolver: (@Sendable () -> Assets?)? = nil,
        portListeners: (@Sendable (Int) -> [Int32]?)? = nil,
        retryScheduler: (@Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void)? = nil
    ) {
        precondition((1...65_535).contains(port))
        self.port = port
        self.assetResolver = assetResolver ?? {
            Self.resolveAssets(modelFileProvider: modelFileProvider)
        }
        self.portListeners = portListeners ?? { Self.lsofListeners(port: $0) }
        self.retryScheduler = retryScheduler
    }

    func start() {
        lifecycle.async { [weak self] in
            guard let self else { return }
            stopped = false
            blockedBy = nil
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
            blockedBy = nil
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
        let binary = bundledBinaryPath
        let bundlePath = Bundle.main.bundlePath
        guard sealPassMemo.check(
            fingerprint: { BundleSealPassMemo.helperSealFingerprint(bundlePath: bundlePath) },
            validate: validCurrentBundleSeal
        ),
              FileManager.default.isExecutableFile(atPath: binary),
              let model = modelFileProvider() else { return nil }
        return Assets(binary: binary, model: "/dev/fd/0", modelInput: model.handle)
    }

    private static var bundledBinaryPath: String {
        Bundle.main.bundlePath + "/Contents/Helpers/llama-server"
    }

    /// Reaps a helper that outlived a crashed app. Same rule as the reap
    /// before every launch: only this app's own helper binary, only once
    /// launchd has adopted it, and only when it's the port's sole listener.
    /// Shells out to `lsof`/`ps`, so never call it on the main thread.
    static func reapOrphanedHelper(port: Int) {
        _ = preparePort(for: bundledBinaryPath, port: port, listeners: { lsofListeners(port: $0) })
    }

    /// See `BundleSealPassMemo`: today's whole-bundle check, run again only
    /// when the helper or the bundle's seal file changes.
    private static let sealPassMemo = BundleSealPassMemo()

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
        let blocked = blockedBy
        let port = self.port
        let listeners = portListeners
        preparation.async { [weak self] in
            guard let self else { return }
            // The same listener the reap rule refused last time still holds
            // the port, so the full path would refuse again. Skip the seal
            // check, the model clone and lsof; the retry ladder is unchanged.
            if let blocked, Self.stillBlockedNow(blocked, port: port) {
                self.lifecycle.async { [weak self] in self?.finishBlockedRetry() }
                return
            }
            let assets = self.assetResolver()
            let result = assets.map {
                Self.preparePort(for: $0.binary, port: port, listeners: listeners)
            } ?? .unavailable
            self.lifecycle.async { [weak self] in
                self?.finishPreparation(assets, result)
            }
        }
    }

    private func finishPreparation(_ assets: Assets?, _ result: PortPreparation) {
        preparing = false
        guard !stopped, process == nil else { return }
        guard let assets else {
            blockedBy = nil
            runtimeSnapshot = .failed(.assetsMissing)
            DiagnosticsLog.shared.record("llama-server-unavailable", metadata: ["reason": "assets-missing"])
            return
        }
        switch result {
        case .ready:
            blockedBy = nil
            launchPrepared(assets)
        case let .blocked(pids):
            blockedBy = BlockedPort(binary: assets.binary, pids: pids)
            recordPortInUseAndRetry()
        case .unavailable:
            blockedBy = nil
            recordPortInUseAndRetry()
        }
    }

    private func finishBlockedRetry() {
        preparing = false
        guard !stopped, process == nil, blockedBy != nil else { return }
        recordPortInUseAndRetry()
    }

    private func recordPortInUseAndRetry() {
        DiagnosticsLog.shared.record("llama-server-unavailable", metadata: ["reason": "port-in-use"])
        scheduleRestart(reason: .portInUse, wasHealthy: false, uptime: 0)
    }

    /// Runs only on `lifecycle`, so stop/restart cannot race child creation.
    /// The child is published only after Process.run() succeeds.
    private func launchPrepared(_ assets: Assets) {
        guard !stopped, process == nil else { return }
        guard let apiKey = accessKey.rotate() else {
            DiagnosticsLog.shared.record("llama-server-unavailable", metadata: ["reason": "launch-failed"])
            scheduleRestart(reason: .launchFailed, wasHealthy: false, uptime: 0)
            return
        }
        let launch = Self.launchConfiguration(
            model: assets.model,
            port: port,
            apiKey: apiKey,
            inheritedEnvironment: ProcessInfo.processInfo.environment,
            physicalMemoryBytes: physicalMemoryBytes
        )
        let child = Process()
        child.executableURL = URL(fileURLWithPath: assets.binary)
        child.arguments = launch.arguments
        child.environment = launch.environment
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

    struct LaunchConfiguration: Equatable, Sendable {
        let arguments: [String]
        let environment: [String: String]
    }

    /// Transcripted divergence from Tilde: the helper requires a per-launch
    /// API key and runs with its web UI off (see `LlamaServerAccessKey`).
    /// The key goes in the environment, never argv, so `ps` can't show it.
    /// `/health` stays public in llama-server, so the readiness probe works
    /// either way; the app sends the key there too.
    ///
    /// Perf divergences from Tilde (docs/writing-port-ledger.md, Deviations):
    /// - `-np 1`: the app serves one request at a time (the keyboard cancels
    ///   a superseded one), and `ScaffoldPrewarmer` and the engine's early
    ///   stop rely on a single slot. The auto default of 4 slots with a
    ///   unified KV cache pinned 3 idle recurrent states on Qwen (~150 MB) and
    ///   sent an overlapping request to a cold slot (a full prefill). Any
    ///   future second consumer of the helper needs its own design (its own
    ///   slot via `id_slot`, or its own helper), not a bigger `-np`.
    /// - `--cache-ram`: RAM-tiered, and left out at 64 GiB and up; see
    ///   `promptCacheMiB(physicalMemoryBytes:)`.
    /// - `--poll 0`: every layer runs on Metal, so the CPU pool only does the
    ///   embedding lookup. The pinned build defaults to `--poll 50`, which
    ///   keeps the idle workers spinning after every token (~90% of the
    ///   helper's CPU per suggestion). 0 makes them sleep instead; output and
    ///   latency don't change. Batch threads inherit it; if `-tb` is ever
    ///   added, add `--poll-batch 0` with it. Don't lower `-t`.
    static func launchConfiguration(
        model: String,
        port: Int,
        apiKey: String,
        inheritedEnvironment: [String: String],
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> LaunchConfiguration {
        var environment = inheritedEnvironment
        environment[LlamaServerAccessKey.environmentVariable] = apiKey
        let promptCache = promptCacheMiB(physicalMemoryBytes: physicalMemoryBytes)
            .map { ["--cache-ram", String($0)] } ?? []
        return LaunchConfiguration(
            arguments: [
                "-m", model,
                "--host", "127.0.0.1",
                "--port", String(port),
                "-c", "4096",
                "-np", "1",
                "--swa-full",
                "--cache-reuse", "256",
            ] + promptCache + [
                "--poll", "0",
                "--no-webui",
            ],
            environment: environment
        )
    }

    /// The helper keeps prompts it moves out of its slot in a host RAM cache
    /// so a return to an earlier context restores (0.08-0.6 s) instead of
    /// re-prefilling (~1.2 s). The pinned build caps that cache at 8 GiB, and
    /// macOS malloc keeps the freed blocks, so on Qwen (~180 MB per entry) the
    /// helper could climb toward 8.5 GB over a day of context switches.
    /// Tiered by RAM so small Macs avoid swap while big Macs keep today's
    /// revisit speed: 64 GiB and up passes nothing (nil: the build's 8 GiB
    /// default, same as before), 32 GiB and up gets 4096 MiB, anything less
    /// 1024 MiB. Every cap holds at least 3 worst-case Qwen entries (~330 MiB
    /// at 4,096 tokens); eviction is oldest first. Never 0 or -1 (off and
    /// unlimited).
    static func promptCacheMiB(physicalMemoryBytes: UInt64) -> Int? {
        let gibibyte: UInt64 = 1 << 30
        if physicalMemoryBytes >= 64 * gibibyte { return nil }
        if physicalMemoryBytes >= 32 * gibibyte { return 4_096 }
        return 1_024
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
        guard let retryScheduler else {
            lifecycle.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.prepareLaunch()
            }
            return
        }
        retryScheduler(delay) { [weak self] in
            self?.lifecycle.async { [weak self] in self?.prepareLaunch() }
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
        accessKey.authorize(&request)
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

    enum PortPreparation: Equatable {
        case ready
        /// The reap rule refused these listeners (lsof answered).
        case blocked([Int32])
        /// lsof failed or timed out, or a listener survived a reap.
        case unavailable
    }

    /// The listeners the reap rule refused on the last attempt, and the
    /// helper binary that attempt resolved.
    struct BlockedPort: Equatable, Sendable {
        let binary: String
        let pids: [Int32]
    }

    /// True only while the full path would refuse again for the same reason:
    /// every remembered pid still listens on the port (so a fresh lsof set
    /// contains them all) and the reap rule, rerun with fresh path and parent
    /// answers, still refuses them. Anything else takes the full path.
    static func stillBlocked(
        _ blocked: BlockedPort,
        port: Int,
        isListening: (Int32, Int) -> Bool,
        executablePath: (Int32) -> String?,
        parentProcess: (Int32) -> String?
    ) -> Bool {
        !blocked.pids.isEmpty
            && blocked.pids.allSatisfy { isListening($0, port) }
            && orphanToReap(
                listeners: blocked.pids,
                binary: blocked.binary,
                executablePath: executablePath,
                parentProcess: parentProcess
            ) == nil
    }

    private static func stillBlockedNow(_ blocked: BlockedPort, port: Int) -> Bool {
        stillBlocked(
            blocked,
            port: port,
            isListening: { holdsListeningSocket(pid: $0, port: $1) },
            executablePath: { processPath(pid: $0) },
            parentProcess: { parentProcessID(of: $0) }
        )
    }

    /// Reap only a re-parented helper from this exact app asset. Any other
    /// listener is left untouched and keeps this runtime unavailable.
    private static func preparePort(
        for binary: String,
        port: Int,
        listeners lookUpListeners: (Int) -> [Int32]?
    ) -> PortPreparation {
        guard let listeners = lookUpListeners(port) else { return .unavailable }
        guard !listeners.isEmpty else { return .ready }
        guard let pid = orphanToReap(
            listeners: listeners,
            binary: binary,
            executablePath: { processPath(pid: $0) },
            parentProcess: { parentProcessID(of: $0) }
        ) else { return .blocked(listeners) }
        kill(pid, SIGTERM)
        usleep(200_000)
        guard let remaining = lookUpListeners(port) else { return .unavailable }
        return remaining.isEmpty ? .ready : .unavailable
    }

    private static func lsofListeners(port: Int) -> [Int32]? {
        command("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]).map {
            $0.split(whereSeparator: \Character.isNewline).compactMap { Int32($0) }
        }
    }

    private static func parentProcessID(of pid: Int32) -> String? {
        command("/bin/ps", ["-o", "ppid=", "-p", String(pid)])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The listener that may be killed, if any: the port's only listener,
    /// running this exact helper binary, re-parented to launchd (pid 1).
    /// Anything else is someone else's process and is left alone.
    static func orphanToReap(
        listeners: [Int32],
        binary: String,
        executablePath: (Int32) -> String?,
        parentProcess: (Int32) -> String?
    ) -> Int32? {
        guard listeners.count == 1, let pid = listeners.first,
              executablePath(pid) == URL(fileURLWithPath: binary).standardizedFileURL.path,
              parentProcess(pid) == "1" else { return nil }
        return pid
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

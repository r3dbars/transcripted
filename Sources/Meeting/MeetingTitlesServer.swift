import Foundation
import Security

/// A short-lived `llama-server` child just for meeting titles. It reuses the
/// helper binary the app bundles for Writing but never shares Writing's
/// process, port or model: its own port, its own per-launch API key, bound to
/// 127.0.0.1 with the web UI off, and the model passed as an already-verified
/// open file. Every request first rechecks that the listener on the port is
/// this child. It is started when the titles queue has work and stopped when
/// the queue empties.
final class MeetingTitlesLlamaServer: MeetingTitlesEngineHost, MeetingTitlesEngine, @unchecked Sendable {
    /// Writing's helper uses 17891 (17875 for its preview build).
    static let defaultPort = 17_893

    struct Configuration: Sendable {
        var helperURL: URL
        var port: Int = MeetingTitlesLlamaServer.defaultPort
        /// The app checks its own code signature (nested code included) before
        /// launching the helper, as Writing does. Off only for the lab check
        /// that runs a helper outside an app bundle.
        var requiresBundleSeal = true
        var healthTimeout: Duration = .seconds(180)
        var requestTimeout: TimeInterval = 600

        static var bundled: Configuration {
            Configuration(helperURL: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/llama-server", isDirectory: false))
        }
    }

    /// The tested flags. `-c 40960` holds the whole transcript of a long
    /// meeting (see `MeetingTitlesFit`); one slot; all layers on the GPU.
    static func launchArguments(port: Int) -> [String] {
        [
            "-m", "/dev/fd/0",
            "--host", "127.0.0.1",
            "--port", String(port),
            "-c", "40960",
            "-np", "1",
            "-ngl", "99",
            "-fa", "on",
            "--jinja",
            "--no-webui",
        ]
    }

    static let apiKeyEnvironmentVariable = "LLAMA_API_KEY"

    private let configuration: Configuration
    private let openModel: @Sendable () throws -> FileHandle
    private let lock = NSLock()
    private var process: Process?
    private var apiKey: String?
    private let session: URLSession

    init(configuration: Configuration, openModel: @escaping @Sendable () throws -> FileHandle) {
        precondition((1...65_535).contains(configuration.port))
        self.configuration = configuration
        self.openModel = openModel
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.connectionProxyDictionary = [:]
        session = URLSession(configuration: sessionConfiguration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(configuration.port)")! }

    var isRunning: Bool { lock.withLock { process?.isRunning == true } }

    // MARK: - Lifecycle

    func start() async throws -> any MeetingTitlesEngine {
        if let child = lock.withLock({ process }), child.isRunning,
           Self.holdsListeningSocket(pid: child.processIdentifier, port: configuration.port) {
            return self
        }
        await stop()
        let helperPath = configuration.helperURL.standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw MeetingTitlesEngineError.helperMissing
        }
        if configuration.requiresBundleSeal, !Self.bundleSealIsValid() {
            throw MeetingTitlesEngineError.bundleSealInvalid
        }
        let model = try openModel()
        defer { try? model.close() }
        let port = configuration.port
        await Task.detached(priority: .utility) {
            Self.reapOrphanedHelper(helperPath: helperPath, port: port)
        }.value
        guard let key = Self.generateKey() else { throw MeetingTitlesEngineError.launchFailed }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: helperPath)
        child.arguments = Self.launchArguments(port: port)
        var environment = ProcessInfo.processInfo.environment
        environment[Self.apiKeyEnvironmentVariable] = key
        child.environment = environment
        child.standardInput = model
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            throw MeetingTitlesEngineError.launchFailed
        }
        lock.withLock {
            process = child
            apiKey = key
        }
        do {
            try await waitUntilHealthy(child)
        } catch {
            await stop()
            throw error
        }
        return self
    }

    func stop() async {
        let child: Process? = lock.withLock {
            defer { process = nil; apiKey = nil }
            return process
        }
        guard let child else { return }
        await Task.detached(priority: .utility) { Self.shutDownNow(child) }.value
    }

    /// At launch: the same strict rule as before each start (sole listener
    /// on the titles port, this exact helper binary, adopted by launchd).
    func reapOrphaned() async {
        let helperPath = configuration.helperURL.standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: helperPath), !isRunning else { return }
        let port = configuration.port
        await Task.detached(priority: .utility) {
            Self.reapOrphanedHelper(helperPath: helperPath, port: port)
        }.value
    }

    /// Synchronous stop for app termination.
    func stopNow() {
        let child: Process? = lock.withLock {
            defer { process = nil; apiKey = nil }
            return process
        }
        Self.shutDownNow(child)
    }

    private func waitUntilHealthy(_ child: Process) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + configuration.healthTimeout
        var delay = Duration.milliseconds(100)
        while clock.now < deadline {
            try Task.checkCancellation()
            guard child.isRunning else { throw MeetingTitlesEngineError.launchFailed }
            if await probeHealth(), Self.holdsListeningSocket(pid: child.processIdentifier, port: configuration.port) {
                return
            }
            try await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(1))
        }
        throw MeetingTitlesEngineError.healthTimeout
    }

    private func probeHealth() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        authorize(&request)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).contains("ok")
    }

    // MARK: - Requests

    func countTokens(_ text: String) async throws -> Int {
        let body = try JSONSerialization.data(withJSONObject: ["content": text])
        let data = try await post("tokenize", body: body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [Any] else { throw MeetingTitlesEngineError.requestFailed }
        return tokens.count
    }

    func chat(body: Data) async throws -> String {
        let data = try await post("v1/chat/completions", body: body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw MeetingTitlesEngineError.requestFailed
        }
        return message["content"] as? String ?? ""
    }

    private func post(_ path: String, body: Data) async throws -> Data {
        guard let child = lock.withLock({ process }), child.isRunning,
              Self.holdsListeningSocket(pid: child.processIdentifier, port: configuration.port) else {
            throw MeetingTitlesEngineError.notRunning
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MeetingTitlesEngineError.requestFailed }
        return data
    }

    private func authorize(_ request: inout URLRequest) {
        guard let key = lock.withLock({ apiKey }) else { return }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    // MARK: - Process helpers

    /// 32 bytes from the system CSPRNG, hex. Lives only in memory and in the
    /// child's environment (not argv, so `ps` can't show it).
    static func generateKey() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The whole-bundle signature check runs once per launch.
    private static let sealMemo = SealMemo()

    private final class SealMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Bool?

        func value(_ compute: () -> Bool) -> Bool {
            lock.withLock {
                if let result { return result }
                let computed = compute()
                result = computed
                return computed
            }
        }
    }

    private static func bundleSealIsValid() -> Bool {
        sealMemo.value {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
                  let code else { return false }
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
            return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
        }
    }

    /// Bounded TERM, then KILL.
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

    /// A titles helper left behind by a crashed app keeps ~3.5 GB. Reap it
    /// only when it is the port's sole listener, runs this exact helper
    /// binary, and launchd has adopted it. Anything else is left alone.
    static func reapOrphanedHelper(helperPath: String, port: Int) {
        let listeners = allPIDs().filter { holdsListeningSocket(pid: $0, port: port) }
        guard listeners.count == 1, let pid = listeners.first,
              processPath(pid: pid) == URL(fileURLWithPath: helperPath).standardizedFileURL.path,
              parentPID(of: pid) == 1 else { return }
        kill(pid, SIGTERM)
        usleep(300_000)
        if holdsListeningSocket(pid: pid, port: port) { kill(pid, SIGKILL) }
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 0 }
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func processPath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL.path
    }

    /// True when `pid` holds a TCP socket in LISTEN on `port`. Fails closed.
    static func holdsListeningSocket(pid: pid_t, port: Int) -> Bool {
        let entrySize = MemoryLayout<proc_fdinfo>.stride
        let sized = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sized > 0 else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(sized) / entrySize)
        guard !descriptors.isEmpty else { return false }
        let capacity = Int32(descriptors.count * entrySize)
        let written = descriptors.withUnsafeMutableBufferPointer { buffer -> Int32 in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, capacity)
        }
        guard written > 0 else { return false }
        let wanted = Int32(MemoryLayout<socket_fdinfo>.stride)
        let usable = min(descriptors.count, Int(written) / entrySize)
        for index in 0..<usable where descriptors[index].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, descriptors[index].proc_fd, PROC_PIDFDSOCKETINFO, &info, wanted) == wanted,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let listening = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if Int(listening) == port { return true }
        }
        return false
    }
}

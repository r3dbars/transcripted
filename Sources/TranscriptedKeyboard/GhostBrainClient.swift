#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation
import Security

/// One cancellable, newline-delimited streaming request to Tilde's owner-only
/// unix socket. The connection is closed on task cancellation, which also
/// gives the app a concrete disconnect signal to cancel model inference.
enum GhostBrainClient {
    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(TildeProductProfile.current.supportDirectoryName)
            .appendingPathComponent("ghost.sock")
            .path
    }

    private static let timeoutNanoseconds: UInt64 = 2_000_000_000
    private static let worker = DispatchQueue(
        label: "com.justinbetker.draft.ghost-client",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// `onPartial` is invoked on the client's worker queue with each stable
    /// streamed prefix (a non-final line carrying non-empty text, plus the
    /// app's register receipt); callers must hop to their own actor.
    static func complete(
        context: String,
        app: String?,
        fieldSessionIdentifier: String? = nil,
        experimentArm: String? = nil,
        opportunityID: String? = nil,
        onPartial: (@Sendable (GhostBrainResponse) -> Void)? = nil
    ) async -> GhostBrainResponse {
        await send(
            GhostBrainRequest(
                context: context,
                app: app,
                fieldSessionIdentifier: fieldSessionIdentifier,
                experimentArm: experimentArm,
                opportunityID: opportunityID
            ),
            onPartial: onPartial
        )
    }

    static func recordPersonalHistory(
        _ events: [PersonalHistoryEvent]
    ) async -> GhostBrainResponse {
        guard PersonalHistoryEvent.validBatch(events) else { return .invalidRequest }
        return await send(GhostBrainRequest(personalHistoryEvents: events))
    }

    static func notifyScreenMemory(_ event: ScreenMemoryInputEvent) async -> GhostBrainResponse {
        await send(GhostBrainRequest(screenMemoryEvent: event))
    }

    static func personalHistoryPayloadFits(_ events: [PersonalHistoryEvent]) -> Bool {
        PersonalHistoryEvent.validBatch(events)
            && encoded(GhostBrainRequest(personalHistoryEvents: events)) != nil
    }

    private static func send(
        _ request: GhostBrainRequest,
        onPartial: (@Sendable (GhostBrainResponse) -> Void)? = nil
    ) async -> GhostBrainResponse {
        guard let payload = encoded(request) else { return .invalidRequest }
        guard let connection = Connection(path: socketPath) else { return .unavailable }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                worker.async {
                    continuation.resume(returning: connection.run(payload: payload, onPartial: onPartial))
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func encoded(_ request: GhostBrainRequest) -> Data? {
        guard let payload = try? JSONEncoder().encode(request),
              payload.count + 1 <= GhostBrainRequest.maximumWireBytes else { return nil }
        return payload
    }

    private final class Connection: @unchecked Sendable {
        private let fd: Int32
        /// Idle deadline: every received line extends it, so a stream that is
        /// still producing stable words is never torn down mid-sentence.
        private var deadline: UInt64
        private let lock = NSLock()
        private var cancelled = false
        private var closed = false
        private var receiveBuffer = Data()

        init?(path: String) {
            let directory = (path as NSString).deletingLastPathComponent
            var directoryInfo = stat()
            var info = stat()
            guard lstat(directory, &directoryInfo) == 0,
                  directoryInfo.st_mode & S_IFMT == S_IFDIR,
                  directoryInfo.st_uid == getuid(),
                  directoryInfo.st_mode & 0o777 == 0o700,
                  lstat(path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFSOCK,
                  info.st_uid == getuid(),
                  info.st_mode & 0o777 == 0o600 else { return nil }
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                if fd >= 0 { close(fd) }
                return nil
            }
            var noSigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        }

        func cancel() {
            lock.lock()
            cancelled = true
            if !closed { shutdown(fd, SHUT_RDWR) }
            lock.unlock()
        }

        func run(
            payload: Data,
            onPartial: (@Sendable (GhostBrainResponse) -> Void)? = nil
        ) -> GhostBrainResponse {
            defer { finish() }
            guard !isCancelled, connect(), !isCancelled, verifyPeer() else { return .unavailable }
            guard write(payload + [0x0A]) else { return timedOut ? .timeout : .unavailable }
            while !timedOut, !isCancelled {
                guard let line = readLine(maximumBytes: 8_192) else {
                    return timedOut ? .timeout : .unavailable
                }
                deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
                let event = GhostBrainResponse.decode(line)
                if !event.final {
                    if let text = event.suggestion, !text.isEmpty { onPartial?(event) }
                    continue
                }
                return event
            }
            return timedOut ? .timeout : .unavailable
        }

        private func connect() -> Bool {
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathOK = GhostBrainClient.socketPath.withCString { path in
                withUnsafeMutableBytes(of: &address.sun_path) { bytes -> Bool in
                    guard strlen(path) < bytes.count else { return false }
                    bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
                        .update(from: path, count: strlen(path) + 1)
                    return true
                }
            }
            guard pathOK else { return false }
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, size)
                }
            }
            if result == 0 { return true }
            guard errno == EINPROGRESS, wait(for: Int16(POLLOUT)) else { return false }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
        }

        private func verifyPeer() -> Bool {
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
#if DEBUG
            if Bundle.main.bundleIdentifier != TildeProductProfile.current.inputMethodBundleIdentifier {
                return ProcessInfo.processInfo.environment["TRANSCRIPTED_WRITING_ALLOW_UNSIGNED_LOCAL_PEER"] == "1"
            }
#else
            guard Bundle.main.bundleIdentifier == TildeProductProfile.current.inputMethodBundleIdentifier else {
                return false
            }
#endif
            var pid: pid_t = 0
            var length = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return false }
            guard let peer = Self.cachedIdentity(pid: pid),
                  peer.identifier == TildeProductProfile.current.appBundleIdentifier,
                  let own = Self.cachedIdentity(pid: getpid()) else { return false }
#if DEBUG
            if let ownTeam = own.team, let peerTeam = peer.team {
                return ownTeam == peerTeam
            }
            return own.team == nil
                && peer.team == nil
                && ProcessInfo.processInfo.environment["TRANSCRIPTED_WRITING_ALLOW_UNSIGNED_LOCAL_PEER"] == "1"
#else
            guard let ownTeam = own.team, let peerTeam = peer.team else { return false }
            return ownTeam == peerTeam
#endif
        }

        /// Two Security-framework identity resolutions (the app's and our
        /// own) ran on every completion request — per typed word — and were
        /// the largest fixed cost on the socket. A live process instance
        /// cannot change its code, so the answer is remembered per (pid,
        /// kernel start time); see `ProcessPeerIdentityCache`. When the
        /// start time cannot be read the identity is resolved uncached,
        /// exactly as before.
        private static let identityCache = ProcessPeerIdentityCache<CodeSigningIdentity>()

        private static func cachedIdentity(pid: pid_t) -> CodeSigningIdentity? {
            identityCache.identity(for: processKey(pid: pid)) { identity(pid: pid) }
        }

        private static func processKey(pid: pid_t) -> ProcessIdentityKey? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return ProcessIdentityKey(
                pid: pid,
                startedAtSeconds: Int64(info.pbi_start_tvsec),
                startedAtMicroseconds: Int64(info.pbi_start_tvusec)
            )
        }

        private static func identity(pid: pid_t) -> CodeSigningIdentity? {
            var code: SecCode?
            let attributes = [kSecGuestAttributePid: pid] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
                  let code,
                  SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
                  let staticCode else { return nil }
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information
            ) == errSecSuccess,
                  let values = information as? [CFString: Any],
                  let identifier = values[kSecCodeInfoIdentifier] as? String else { return nil }
            return CodeSigningIdentity(
                identifier: identifier,
                team: values[kSecCodeInfoTeamIdentifier] as? String
            )
        }

        private func write(_ data: Data) -> Bool {
            var offset = 0
            return data.withUnsafeBytes { bytes in
                while offset < bytes.count {
                    guard wait(for: Int16(POLLOUT)) else { return false }
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else {
                        if errno == EINTR || errno == EAGAIN { continue }
                        return false
                    }
                    offset += count
                }
                return true
            }
        }

        private func readLine(maximumBytes: Int) -> Data? {
            var buffer = [UInt8](repeating: 0, count: 2_048)
            while true {
                if let newline = receiveBuffer.firstIndex(of: 0x0A) {
                    let line = receiveBuffer.prefix(upTo: newline)
                    receiveBuffer.removeSubrange(...newline)
                    return Data(line)
                }
                guard receiveBuffer.count < maximumBytes else { return nil }
                guard wait(for: Int16(POLLIN)) else { return nil }
                let count = Darwin.read(
                    fd,
                    &buffer,
                    min(buffer.count, maximumBytes - receiveBuffer.count)
                )
                guard count > 0 else {
                    if count < 0, errno == EINTR || errno == EAGAIN { continue }
                    return nil
                }
                receiveBuffer.append(contentsOf: buffer[0..<count])
            }
        }

        private func wait(for events: Int16) -> Bool {
            while !timedOut {
                if isCancelled { return false }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return false }
                let milliseconds = Int32(max(1, (deadline - now) / 1_000_000))
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let result = poll(&descriptor, 1, milliseconds)
                if result > 0 {
                    return descriptor.revents & events != 0
                }
                if result < 0, errno == EINTR { continue }
                return false
            }
            return false
        }

        private var timedOut: Bool {
            DispatchTime.now().uptimeNanoseconds >= deadline
        }

        private var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        private func finish() {
            lock.lock()
            if !closed {
                closed = true
                close(fd)
            }
            lock.unlock()
        }
    }
}

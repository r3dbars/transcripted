#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation
import Security

/// Owner-only unix socket between Transcripted and its capture keyboard.
/// Accepts only authenticated writing-capture batches from the signed keyboard
/// and routes them to the app-owned Markdown day-file recorder.
final class GhostBrainServerHost: @unchecked Sendable {
    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(TildeProductProfile.current.supportDirectoryName)
            .appendingPathComponent("ghost.sock")
            .path
    }

    private let personalHistory: any PersonalHistoryIngesting
    private let queue = DispatchQueue(label: "com.justinbetker.draft.ghost-brain-server")
    private var listenerFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var ownsSocket = false

    init(personalHistory: any PersonalHistoryIngesting) {
        self.personalHistory = personalHistory
    }

    func start() -> Bool {
        queue.sync { bindAndListen() }
    }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            if listenerFD >= 0 { close(listenerFD) }
            listenerFD = -1
            if ownsSocket { unlink(Self.socketPath) }
            ownsSocket = false
            if lockFD >= 0 {
                flock(lockFD, LOCK_UN)
                close(lockFD)
            }
            lockFD = -1
        }
    }

    static func personalHistoryResponse(
        _ events: [PersonalHistoryEvent],
        ingest: any PersonalHistoryIngesting
    ) async -> GhostBrainResponse {
        await ingest.recordingResponse(events)
    }

    private func bindAndListen() -> Bool {
        let directory = (Self.socketPath as NSString).deletingLastPathComponent
        guard Self.secureSocketDirectory(directory) else {
            DiagnosticsLog.shared.record("ghost-socket-unavailable", metadata: ["reason": "directory"])
            return false
        }
        let lockPath = directory + "/runtime.lock"
        let lockFD = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        var lockInfo = stat()
        guard lockFD >= 0,
              fcntl(lockFD, F_SETFD, FD_CLOEXEC) == 0,
              fchmod(lockFD, S_IRUSR | S_IWUSR) == 0,
              fstat(lockFD, &lockInfo) == 0,
              lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == getuid(),
              lockInfo.st_mode & 0o777 == 0o600,
              flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD) }
            DiagnosticsLog.shared.record("ghost-socket-unavailable", metadata: ["reason": "already-running"])
            return false
        }
        self.lockFD = lockFD
        unlink(Self.socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            if fd >= 0 { close(fd) }
            releaseLock()
            return false
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathOK = Self.socketPath.withCString { path in
            withUnsafeMutableBytes(of: &address.sun_path) { bytes -> Bool in
                guard strlen(path) < bytes.count else { return false }
                bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
                    .update(from: path, count: strlen(path) + 1)
                return true
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = pathOK && withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 }
        }
        guard bound, listen(fd, 8) == 0, chmod(Self.socketPath, 0o600) == 0,
              Self.isOwnerOnlySocket(Self.socketPath) else {
            close(fd)
            unlink(Self.socketPath)
            releaseLock()
            return false
        }
        listenerFD = fd
        ownsSocket = true
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        self.source = source
        return true
    }

    private func releaseLock() {
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }
        lockFD = -1
    }

    private func acceptOne() {
        let connection = accept(listenerFD, nil, nil)
        guard connection >= 0 else { return }
        guard fcntl(connection, F_SETFD, FD_CLOEXEC) == 0 else {
            close(connection)
            return
        }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        Task.detached(priority: .userInitiated) { [weak self] in
            defer { close(connection) }
            guard let self else { return }
            guard Self.authorizedPeer(connection) else {
                _ = Self.write(.unavailable, to: connection)
                return
            }
            guard case let .success(request) = Self.readRequest(connection) else {
                _ = Self.write(.invalidRequest, to: connection)
                return
            }
            switch request {
            case let .personalHistory(events):
                let response = await Self.personalHistoryResponse(events, ingest: self.personalHistory)
                _ = Self.write(response, to: connection)
            case let .unsupportedPersonalHistory(rejectedEventIDs):
                DiagnosticsLog.shared.record("personal-history-unsupported-version", metadata: [:])
                _ = Self.write(.unsupported(rejectedEventIDs: rejectedEventIDs), to: connection)
            }
        }
    }

    private enum ValidatedRequest {
        case personalHistory([PersonalHistoryEvent])
        case unsupportedPersonalHistory([String])
    }

    private enum WireError: Error { case invalid }

    private static func readRequest(_ fd: Int32) -> Result<ValidatedRequest, Error> {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count < GhostBrainRequest.maximumWireBytes {
            let count = Darwin.read(
                fd,
                &buffer,
                min(buffer.count, GhostBrainRequest.maximumWireBytes - data.count)
            )
            guard count > 0 else { return .failure(WireError.invalid) }
            data.append(contentsOf: buffer[0..<count])
            guard let newline = data.firstIndex(of: 0x0A) else { continue }
            data = data.prefix(upTo: newline)
            guard let request = try? JSONDecoder().decode(GhostBrainRequest.self, from: data),
                  request.v == GhostBrainRequest.version else {
                if let rejected = GhostBrainRequest.unsupportedPersonalHistoryEventIDs(in: data) {
                    return .success(.unsupportedPersonalHistory(rejected))
                }
                return .failure(WireError.invalid)
            }
            guard let events = request.personalHistoryEvents,
                  request.context.isEmpty,
                  PersonalHistoryEvent.validBatch(events) else {
                return .failure(WireError.invalid)
            }
            return .success(.personalHistory(events))
        }
        return .failure(WireError.invalid)
    }

    private static func write(_ response: GhostBrainResponse, to fd: Int32) -> Bool {
        guard var data = try? JSONEncoder().encode(response) else { return false }
        data.append(0x0A)
        var offset = 0
        return data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
    }

    private static func authorizedPeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
#if DEBUG
        if Bundle.main.bundleIdentifier != TildeProductProfile.current.appBundleIdentifier {
            return ProcessInfo.processInfo.environment["TRANSCRIPTED_WRITING_ALLOW_UNSIGNED_LOCAL_PEER"] == "1"
        }
#else
        guard Bundle.main.bundleIdentifier == TildeProductProfile.current.appBundleIdentifier else { return false }
#endif
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return false }
        guard let peer = cachedIdentity(pid: pid),
              peer.identifier == TildeProductProfile.current.inputMethodBundleIdentifier,
              let own = cachedIdentity(pid: getpid()) else { return false }
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
        guard SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributePid: pid] as CFDictionary,
            [],
            &code
        ) == errSecSuccess, let code,
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

    private static func secureSocketDirectory(_ path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            return false
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              chmod(path, 0o700) == 0,
              lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o700 else { return false }
        return true
    }

    private static func isOwnerOnlySocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && info.st_mode & S_IFMT == S_IFSOCK
            && info.st_uid == getuid()
            && info.st_mode & 0o777 == 0o600
    }
}

import Foundation
import Darwin
import Security

enum CompanionSocketError: Error {
    case unsafeDirectory
    case unavailable
    case pathTooLong
}

/// Only this user's processes can reach this socket. The transport is independent
/// of capture and never logs a request, response, path, or connection credential.
final class CompanionSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (CompanionRequest, @escaping @Sendable (Data) -> Void) -> Void

    private final class Client {
        let descriptor: Int32
        var buffer = Data()
        var reader: DispatchSourceRead?
        var deadline: DispatchSourceTimer?
        var processing = false
        init(_ descriptor: Int32) { self.descriptor = descriptor }
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "com.transcripted.companion.socket", qos: .utility)
    private var directoryFD: Int32 = -1
    private var listenerFD: Int32 = -1
    private var listener: DispatchSourceRead?
    private var clients: [UUID: Client] = [:]
    private var token = ""
    private var handler: Handler?
    private var ownedFiles: [String: UInt64] = [:]

    // Preserve the caller's spelling. Foundation standardization on macOS
    // rewrites /private/tmp to the /tmp symlink; openat below checks each real
    // path component and refuses aliases instead of following them.
    init(directory: URL) { self.directory = directory }

    func start(handler: @escaping Handler) throws {
        try queue.sync {
            guard listenerFD < 0 else { return }
            do {
                directoryFD = try Self.openPrivateDirectory(directory)
                try removePreviousEndpoint()
                let path = directory.appendingPathComponent("s").path
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let bytes = Array(path.utf8)
                guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                    throw CompanionSocketError.pathTooLong
                }
                address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                withUnsafeMutableBytes(of: &address.sun_path) { destination in
                    destination.copyBytes(from: bytes + [0])
                }
                listenerFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard listenerFD >= 0 else { throw CompanionSocketError.unavailable }
                _ = fcntl(listenerFD, F_SETFD, FD_CLOEXEC)
                _ = fcntl(listenerFD, F_SETFL, O_NONBLOCK)
                let bound = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard bound == 0 else { throw CompanionSocketError.unavailable }
                var socketInfo = stat()
                guard fstatat(directoryFD, "s", &socketInfo, AT_SYMLINK_NOFOLLOW) == 0,
                      socketInfo.st_mode & S_IFMT == S_IFSOCK, socketInfo.st_uid == getuid(),
                      chmod(path, 0o600) == 0 else { throw CompanionSocketError.unsafeDirectory }
                ownedFiles["s"] = UInt64(socketInfo.st_ino)
                guard Darwin.listen(listenerFD, 8) == 0 else { throw CompanionSocketError.unavailable }
                token = try Self.newToken()
                let connection: [String: Any] = ["protocol_version": CompanionProtocol.version,
                    "socket_path": path, "token": token]
                try writeConnection(try JSONSerialization.data(withJSONObject: connection, options: [.sortedKeys]))
                self.handler = handler
                let source = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: queue)
                source.setEventHandler { [weak self] in self?.acceptClients() }
                listener = source
                source.resume()
            } catch {
                shutDown()
                throw error
            }
        }
    }

    func stop() { queue.sync { shutDown() } }

    private func acceptClients() {
        // A ready listener can accept multiple connections; bound work per event.
        for _ in 0..<16 {
            let fd = Darwin.accept(listenerFD, nil, nil)
            guard fd >= 0 else { return }
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard clients.count < 8, getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else {
                Darwin.close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var noSignal: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let id = UUID()
            let client = Client(fd)
            clients[id] = client
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readClient(id) }
            client.reader = source
            setDeadline(client, id: id, seconds: 5)
            source.resume()
        }
    }

    private func readClient(_ id: UUID) {
        guard let client = clients[id], !client.processing else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(client.descriptor, &bytes, bytes.count, 0)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            guard count > 0 else { closeClient(id); return }
            client.buffer.append(contentsOf: bytes.prefix(count))
            guard client.buffer.count <= CompanionProtocol.maximumRequestBytes + 1 else {
                finish(id, data: CompanionProtocol.response(id: nil, failure: .invalidRequest)); return
            }
            guard let newline = client.buffer.firstIndex(of: 10) else { continue }
            // One complete JSON line per connection, with no pipelined commands.
            guard newline == client.buffer.index(before: client.buffer.endIndex) else {
                finish(id, data: CompanionProtocol.response(id: nil, failure: .invalidRequest)); return
            }
            client.processing = true
            client.reader?.cancel()
            client.reader = nil
            let requestData = Data(client.buffer[..<newline])
            client.buffer.removeAll(keepingCapacity: false)
            switch CompanionProtocol.parse(requestData, token: token) {
            case .failure(let error):
                finish(id, data: CompanionProtocol.response(id: CompanionProtocol.requestID(in: requestData), failure: error))
            case .success(let request):
                // Native meeting startup owns its own capture/permission deadlines.
                // The socket lifetime is bounded even if the client disappears.
                setDeadline(client, id: id, seconds: 150)
                handler?(request) { [weak self] response in
                    guard let self else { return }
                    self.queue.async { [weak self] in self?.finish(id, data: response) }
                }
            }
            return
        }
    }

    private func setDeadline(_ client: Client, id: UUID, seconds: Int) {
        client.deadline?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(seconds))
        timer.setEventHandler { [weak self] in self?.closeClient(id) }
        client.deadline = timer
        timer.resume()
    }

    private func finish(_ id: UUID, data: Data) {
        guard let client = clients[id], data.count <= CompanionProtocol.maximumResponseBytes + 1 else {
            closeClient(id); return
        }
        var offset = 0
        // A response write has a single overall deadline, not a fresh timeout per
        // chunk, so a client that stops consuming cannot hold the server forever.
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < bytes.count {
                let sent = Darwin.send(client.descriptor, base.advanced(by: offset), bytes.count - offset, 0)
                if sent > 0 { offset += sent; continue }
                if sent < 0, errno == EINTR { continue }
                guard sent < 0, errno == EAGAIN || errno == EWOULDBLOCK else { break }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { break }
                var pollFD = pollfd(fd: client.descriptor, events: Int16(POLLOUT), revents: 0)
                let milliseconds = Int32(min(2_000, (deadline - now) / 1_000_000 + 1))
                guard Darwin.poll(&pollFD, 1, milliseconds) > 0 else { break }
            }
        }
        closeClient(id)
    }

    private func closeClient(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.reader?.cancel()
        client.deadline?.cancel()
        _ = Darwin.shutdown(client.descriptor, SHUT_RDWR)
        Darwin.close(client.descriptor)
    }

    private func shutDown() {
        listener?.cancel()
        listener = nil
        for id in Array(clients.keys) { closeClient(id) }
        if listenerFD >= 0 { Darwin.close(listenerFD); listenerFD = -1 }
        if directoryFD >= 0 {
            // Remove only the inodes created by this instance; leave replacements
            // alone if another local process changed the directory.
            for (name, inode) in ownedFiles {
                var info = stat()
                if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                   UInt64(info.st_ino) == inode, info.st_uid == getuid() {
                    _ = unlinkat(directoryFD, name, 0)
                }
            }
            Darwin.close(directoryFD)
            directoryFD = -1
        }
        ownedFiles.removeAll()
        token = ""
        handler = nil
    }

    private func removePreviousEndpoint() throws {
        for (name, kind) in [("connection.json", mode_t(S_IFREG)), ("s", mode_t(S_IFSOCK))] {
            var info = stat()
            if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_uid == getuid(), info.st_mode & S_IFMT == kind,
                      info.st_mode & 0o777 == 0o600,
                      unlinkat(directoryFD, name, 0) == 0 else { throw CompanionSocketError.unsafeDirectory }
            } else if errno != ENOENT { throw CompanionSocketError.unsafeDirectory }
        }
    }

    private func writeConnection(_ data: Data) throws {
        let name = ".connection-\(UUID().uuidString)"
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CompanionSocketError.unavailable }
        defer { Darwin.close(fd); _ = unlinkat(directoryFD, name, 0) }
        var complete = true
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { complete = false; return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { complete = false; return }
                offset += written
            }
        }
        guard complete, fchmod(fd, 0o600) == 0, fsync(fd) == 0,
              renameat(directoryFD, name, directoryFD, "connection.json") == 0 else {
            throw CompanionSocketError.unavailable
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw CompanionSocketError.unavailable }
        ownedFiles["connection.json"] = UInt64(info.st_ino)
    }

    private static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CompanionSocketError.unavailable
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Walk with openat/O_NOFOLLOW instead of resolving a symlink and trusting
    /// where it led. Existing ancestors can be system-owned; the companion
    /// directory itself must belong to this user and be private.
    private static func openPrivateDirectory(_ url: URL) throws -> Int32 {
        guard url.path.hasPrefix("/") else { throw CompanionSocketError.unsafeDirectory }
        var parentFD = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { throw CompanionSocketError.unavailable }
        let components = url.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else {
            Darwin.close(parentFD); throw CompanionSocketError.unsafeDirectory
        }
        for (index, component) in components.enumerated() {
            guard component != ".", component != ".." else {
                Darwin.close(parentFD); throw CompanionSocketError.unsafeDirectory
            }
            if index == components.count - 1 {
                var parentInfo = stat()
                guard fstat(parentFD, &parentInfo) == 0, parentInfo.st_uid == getuid(),
                      parentInfo.st_mode & 0o022 == 0 else {
                    Darwin.close(parentFD); throw CompanionSocketError.unsafeDirectory
                }
            }
            var nextFD = openat(parentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if nextFD < 0, errno == ENOENT {
                guard mkdirat(parentFD, component, 0o700) == 0 || errno == EEXIST else {
                    Darwin.close(parentFD); throw CompanionSocketError.unavailable
                }
                nextFD = openat(parentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            Darwin.close(parentFD)
            guard nextFD >= 0 else { throw CompanionSocketError.unsafeDirectory }
            parentFD = nextFD
            if index == components.count - 1 {
                var info = stat()
                guard fstat(parentFD, &info) == 0, info.st_uid == getuid(),
                      info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
                    Darwin.close(parentFD); throw CompanionSocketError.unsafeDirectory
                }
            }
        }
        return parentFD
    }
}

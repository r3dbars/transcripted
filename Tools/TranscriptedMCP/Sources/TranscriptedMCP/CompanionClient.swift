import Foundation
import Darwin
import MCP

/// Authenticated local transport. Never logs credentials, paths, or native payloads.
struct CompanionClient: Sendable {
    struct Failure: Error, Equatable, LocalizedError {
        let code: String
        var errorDescription: String? {
            switch code {
            case "companion_unavailable": return "Open Transcripted and enable the ChatGPT companion in Settings → Agent."
            case "invalid_connection", "auth_failed": return "The companion connection could not be verified. Turn it off and on in Transcripted."
            case "timeout": return "Transcripted did not reply in time. Check its recording state before trying again."
            case "stale_session": return "That meeting has ended or changed. Refresh the recording status."
            case "permission_denied": return "Enable the requested companion permission in Transcripted. Live text also needs sharing enabled for this meeting."
            case "capture_busy": return "Transcripted already has an active capture."
            case "live_unavailable": return "Live text is not available yet. The final saved transcript will appear after processing."
            case "start_failed": return "Transcripted could not start recording. Check its permissions and models."
            case "invalid_request": return "The companion request is invalid."
            default: return "Transcripted could not complete this request. Refresh its status."
            }
        }
    }

    struct Connection: Codable, Sendable {
        let protocol_version: Int
        let socket_path: String
        let token: String
    }

    let root: URL
    let timeout: TimeInterval
    init(root: URL = CompanionClient.defaultRoot(), timeout: TimeInterval = 8) {
        // Preserve /private/tmp spelling in isolated fixtures. Foundation's
        // standardization can turn it into a symlink alias (/tmp).
        self.root = root
        self.timeout = timeout
    }

    static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let support: URL
        if let path = environment["TRANSCRIPTED_CONTAINER_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") {
            support = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Transcripted", isDirectory: true)
        }
        return support.appendingPathComponent("companion", isDirectory: true)
    }

    func connection() throws -> Connection {
        var directory = stat()
        guard lstat(root.path, &directory) == 0 else { throw Failure(code: "companion_unavailable") }
        guard directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid(), directory.st_mode & 0o077 == 0,
              Self.hasNoSymlinkAncestor(root.path) else { throw Failure(code: "invalid_connection") }
        let file = root.appendingPathComponent("connection.json")
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(code: "companion_unavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 16_384 else {
            throw Failure(code: "invalid_connection")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let byteCount = bytes.count
        var offset = 0
        while offset < byteCount {
            let count = bytes.withUnsafeMutableBytes { buffer in Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), byteCount - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw Failure(code: "invalid_connection") }
            offset += count
        }
        guard let connection = try? JSONDecoder().decode(Connection.self, from: Data(bytes)),
              connection.protocol_version == 1, connection.token.utf8.count >= 32, connection.token.utf8.count <= 512,
              !connection.token.contains("\n"), !connection.token.contains("\0"),
              connection.socket_path.hasPrefix(root.path + "/"), connection.socket_path.utf8.count < 104,
              !String(connection.socket_path.dropFirst(root.path.count + 1)).contains("/"),
              ![".", ".."].contains(String(connection.socket_path.dropFirst(root.path.count + 1))) else {
            throw Failure(code: "invalid_connection")
        }
        var socketInfo = stat()
        guard lstat(connection.socket_path, &socketInfo) == 0,
              socketInfo.st_mode & S_IFMT == S_IFSOCK, socketInfo.st_uid == getuid(), socketInfo.st_mode & 0o077 == 0 else {
            throw Failure(code: "companion_unavailable")
        }
        return connection
    }

    private static func hasNoSymlinkAncestor(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var current = ""
        for component in path.split(separator: "/") {
            guard component != ".", component != ".." else { return false }
            current += "/" + component
            var info = stat()
            guard lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        }
        return true
    }

    func call(_ method: String, params: [String: Value] = [:]) throws -> [String: Value] {
        let connection = try connection()
        let id = UUID().uuidString
        let request: [String: Value] = ["version": .int(1), "token": .string(connection.token), "id": .string(id), "method": .string(method), "params": .object(params)]
        var bytes = try JSONEncoder().encode(request)
        bytes.append(0x0A)
        guard bytes.count <= 32_768 else { throw Failure(code: "invalid_request") }
        let response = try exchange(bytes, socketPath: connection.socket_path)
        return try Self.decodeResponse(response, expectedID: id)
    }

    static func decodeResponse(_ data: Data, expectedID: String) throws -> [String: Value] {
        guard let envelope = try? JSONDecoder().decode([String: Value].self, from: data),
              envelope["version"] == .int(1), envelope["id"] == .string(expectedID) else {
            throw Failure(code: "invalid_response")
        }
        if envelope["ok"] == .bool(true), case .object(let result) = envelope["result"] { return result }
        guard envelope["ok"] == .bool(false), case .object(let error) = envelope["error"], let code = error["code"]?.stringValue,
              code.utf8.count <= 64, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw Failure(code: "invalid_response")
        }
        throw Failure(code: code)
    }

    private func exchange(_ request: Data, socketPath: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(code: "companion_unavailable") }
        defer { close(fd) }
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw Failure(code: "companion_unavailable") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.initializeMemory(as: UInt8.self, repeating: 0)
            target.copyBytes(from: Array(socketPath.utf8))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(timeout, 0)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw Failure(code: "companion_unavailable") }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw Failure(code: "companion_unavailable") }
        }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw Failure(code: "auth_failed") }
        var offset = 0
        while offset < request.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let count = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), request.count - offset, 0) }
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw Failure(code: "companion_unavailable") }
            offset += count
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw Failure(code: "companion_unavailable") }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= 524_288 else { throw Failure(code: "invalid_response") }
            if let newline = result.firstIndex(of: 0x0A) { return Data(result[..<newline]) }
        }
    }

    private func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure(code: "timeout") }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1_000, Double(Int32.max)).rounded(.up)))
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw Failure(code: "companion_unavailable") }
            if result == 0 { throw Failure(code: "timeout") }
            if descriptor.revents & events != 0 { return }
            throw Failure(code: "companion_unavailable")
        }
    }
}

import Foundation
import Network

@available(macOS 14.0, *)
enum LiveMeetingPreviewServerError: LocalizedError {
    case invalidLoopbackAddress
    case listenerFailed(String)
    case listenerStartupTimedOut
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidLoopbackAddress:
            return "Could not bind the live preview server to 127.0.0.1."
        case .listenerFailed(let detail):
            return "Could not start the live preview server: \(detail)"
        case .listenerStartupTimedOut:
            return "The live preview server did not become ready in time."
        case .invalidPort:
            return "Could not use the live preview port."
        }
    }
}

@available(macOS 14.0, *)
final class LiveMeetingPreviewServer {
    static let shared = LiveMeetingPreviewServer()

    private let queue = DispatchQueue(label: "com.transcripted.live-meeting-preview-server")
    private let lock = NSLock()
    private let fileManager: FileManager
    private let port: UInt16
    private var listener: NWListener?
    private var workspaceURL: URL

    init(
        workspaceURL: URL = LiveMeetingCodexSession.defaultWorkspaceRoot,
        fileManager: FileManager = .default,
        port: UInt16 = LiveMeetingCodexSession.previewServerPort
    ) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.fileManager = fileManager
        self.port = port
    }

    func start(workspaceURL: URL = LiveMeetingCodexSession.defaultWorkspaceRoot) throws -> URL {
        let standardizedWorkspaceURL = workspaceURL.standardizedFileURL
        let session = LiveMeetingCodexSession(workspaceRoot: standardizedWorkspaceURL, fileManager: fileManager)
        let authToken = try session.ensurePreviewAuthToken()

        lock.lock()

        self.workspaceURL = standardizedWorkspaceURL
        if listener != nil {
            lock.unlock()
            return authenticatedPreviewServerURL(token: authToken)
        }

        guard let listenerPort = NWEndpoint.Port(rawValue: port) else {
            lock.unlock()
            throw LiveMeetingPreviewServerError.invalidPort
        }
        guard let loopback = IPv4Address("127.0.0.1") else {
            lock.unlock()
            throw LiveMeetingPreviewServerError.invalidLoopbackAddress
        }

        let startupSemaphore = DispatchSemaphore(value: 0)
        let startupLock = NSLock()
        var startupResult: Result<Void, Error>?
        let completeStartup: (Result<Void, Error>) -> Void = { result in
            startupLock.lock()
            defer { startupLock.unlock() }
            guard startupResult == nil else { return }
            startupResult = result
            startupSemaphore.signal()
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: listenerPort)

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            lock.unlock()
            throw error
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            switch state {
            case .ready:
                completeStartup(.success(()))
            case .failed(let error):
                completeStartup(.failure(LiveMeetingPreviewServerError.listenerFailed(error.localizedDescription)))
                self?.clearListener(newListener)
            case .cancelled:
                self?.clearListener(newListener)
            default:
                break
            }
        }
        listener = newListener
        lock.unlock()

        newListener.start(queue: queue)

        guard startupSemaphore.wait(timeout: .now() + 1.0) == .success else {
            clearListener(newListener)
            newListener.cancel()
            throw LiveMeetingPreviewServerError.listenerStartupTimedOut
        }

        switch startupResult {
        case .success:
            break
        case .failure(let error):
            clearListener(newListener)
            newListener.cancel()
            throw error
        case .none:
            clearListener(newListener)
            newListener.cancel()
            throw LiveMeetingPreviewServerError.listenerStartupTimedOut
        }

        return authenticatedPreviewServerURL(token: authToken)
    }

    func stop() {
        lock.lock()
        let existingListener = listener
        listener = nil
        lock.unlock()

        existingListener?.cancel()
    }

    private func clearListener(_ listenerToClear: NWListener? = nil) {
        lock.lock()
        if let listenerToClear {
            if listener === listenerToClear {
                listener = nil
            }
        } else {
            listener = nil
        }
        lock.unlock()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let response = self.response(for: data ?? Data())
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for requestData: Data) -> Data {
        let requestText = String(decoding: requestData, as: UTF8.self)
        let request = parseRequest(requestText)

        guard isAllowedHost(request.headers["host"]) else {
            return httpResponse(
                status: "403 Forbidden",
                contentType: "text/plain; charset=utf-8",
                body: Data("Forbidden".utf8)
            )
        }

        if request.method == "OPTIONS" {
            return httpResponse(status: "204 No Content", contentType: "text/plain; charset=utf-8", body: Data())
        }

        guard request.method == "GET" || request.method == "HEAD" else {
            return httpResponse(
                status: "405 Method Not Allowed",
                contentType: "text/plain; charset=utf-8",
                body: Data("Method not allowed".utf8)
            )
        }

        let route = request.path
        guard route == "/favicon.ico" || isAuthorizedPreviewRequest(token: request.queryItems["token"]) else {
            return httpResponse(
                status: "401 Unauthorized",
                contentType: "text/plain; charset=utf-8",
                body: Data("Unauthorized".utf8)
            )
        }

        switch route {
        case "/", LiveMeetingCodexSession.previewServerPath:
            return fileResponse(filename: LiveMeetingCodexSession.previewFilename, contentType: "text/html; charset=utf-8")
        case "/live-transcript", "/live_transcript.md":
            return fileResponse(filename: LiveMeetingCodexSession.liveTranscriptFilename, contentType: "text/markdown; charset=utf-8")
        case "/handoff", "/agent-handoff.md", "/codex-handoff.md":
            return fileResponse(filename: LiveMeetingCodexSession.handoffFilename, contentType: "text/markdown; charset=utf-8")
        case "/watcher-state", "/agent-watcher-state.json", "/codex-watcher-state.json":
            return fileResponse(filename: LiveMeetingCodexSession.watcherStateFilename, contentType: "application/json; charset=utf-8")
        case "/state", "/state.json":
            return fileResponse(filename: LiveMeetingCodexSession.stateFilename, contentType: "application/json; charset=utf-8")
        case "/favicon.ico":
            return httpResponse(status: "204 No Content", contentType: "image/x-icon", body: Data())
        default:
            return httpResponse(
                status: "404 Not Found",
                contentType: "text/plain; charset=utf-8",
                body: Data("Not found".utf8)
            )
        }
    }

    private func fileResponse(filename: String, contentType: String) -> Data {
        let workspaceURL = currentWorkspaceURL()
        let fileURL = workspaceURL.appendingPathComponent(filename, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL) else {
            return httpResponse(
                status: "503 Service Unavailable",
                contentType: "text/plain; charset=utf-8",
                body: Data("Live preview is not ready yet.".utf8)
            )
        }

        return httpResponse(status: "200 OK", contentType: contentType, body: data)
    }

    private func currentWorkspaceURL() -> URL {
        lock.lock()
        let url = workspaceURL
        lock.unlock()
        return url
    }

    private func parseRequest(_ requestText: String) -> (method: String, path: String, queryItems: [String: String], headers: [String: String]) {
        let lines = requestText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let firstLine = lines.first ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let rawTarget = parts.dropFirst().first.map(String.init) ?? "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                headers[name] = value
            }
        }

        let components = URLComponents(string: rawTarget)
        let targetPath: String
        if let components, components.scheme != nil {
            targetPath = components.path.isEmpty ? "/" : components.path
        } else {
            targetPath = components?.path.isEmpty == false
                ? components?.path ?? "/"
                : rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        }
        let queryItems = (components?.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            result[item.name] = item.value ?? ""
        }

        return (
            method: method.uppercased(),
            path: targetPath.removingPercentEncoding ?? targetPath,
            queryItems: queryItems,
            headers: headers
        )
    }

    private func isAuthorizedPreviewRequest(token: String?) -> Bool {
        guard let expected = expectedPreviewAuthToken(),
              !expected.isEmpty,
              let token,
              !token.isEmpty else {
            return false
        }
        return constantTimeEqual(token, expected)
    }

    private func expectedPreviewAuthToken() -> String? {
        let tokenURL = currentWorkspaceURL()
            .appendingPathComponent(LiveMeetingCodexSession.previewAuthTokenFilename, isDirectory: false)
        return ((try? String(contentsOf: tokenURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        var difference = lhsBytes.count ^ rhsBytes.count
        for index in 0..<max(lhsBytes.count, rhsBytes.count) {
            let left = index < lhsBytes.count ? lhsBytes[index] : 0
            let right = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= Int(left ^ right)
        }
        return difference == 0
    }

    private func isAllowedHost(_ rawHost: String?) -> Bool {
        guard let host = rawHost?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !host.isEmpty else {
            return false
        }

        let allowedHosts = [
            "127.0.0.1",
            "localhost",
            "[::1]",
        ]
        let portSuffix = ":\(port)"

        return allowedHosts.contains(host)
            || allowedHosts.contains { host == "\($0)\(portSuffix)" }
    }

    private func authenticatedPreviewServerURL(token: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = LiveMeetingCodexSession.previewServerPath
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url ?? LiveMeetingCodexSession.authenticatedPreviewServerURL(token: token)
    }

    private func httpResponse(status: String, contentType: String, body: Data) -> Data {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store, no-cache, must-revalidate\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var response = Data(header.utf8)
        response.append(body)
        return response
    }
}

import Foundation
import Network

@available(macOS 14.0, *)
enum LiveMeetingPreviewServerError: LocalizedError {
    case invalidLoopbackAddress
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidLoopbackAddress:
            return "Could not bind the live preview server to 127.0.0.1."
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
    private var listener: NWListener?
    private var workspaceURL: URL

    init(
        workspaceURL: URL = LiveMeetingCodexSession.defaultWorkspaceRoot,
        fileManager: FileManager = .default
    ) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func start(workspaceURL: URL = LiveMeetingCodexSession.defaultWorkspaceRoot) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        self.workspaceURL = workspaceURL.standardizedFileURL
        if listener != nil {
            return LiveMeetingCodexSession.previewServerURL
        }

        guard let port = NWEndpoint.Port(rawValue: LiveMeetingCodexSession.previewServerPort) else {
            throw LiveMeetingPreviewServerError.invalidPort
        }
        guard let loopback = IPv4Address("127.0.0.1") else {
            throw LiveMeetingPreviewServerError.invalidLoopbackAddress
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: port)

        let newListener = try NWListener(using: parameters)
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        newListener.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            self?.clearListener()
        }
        listener = newListener
        newListener.start(queue: queue)

        return LiveMeetingCodexSession.previewServerURL
    }

    func stop() {
        lock.lock()
        let existingListener = listener
        listener = nil
        lock.unlock()

        existingListener?.cancel()
    }

    private func clearListener() {
        lock.lock()
        listener = nil
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
        switch route {
        case "/", LiveMeetingCodexSession.previewServerPath:
            return fileResponse(filename: LiveMeetingCodexSession.previewFilename, contentType: "text/html; charset=utf-8")
        case "/live-transcript", "/live_transcript.md":
            return fileResponse(filename: LiveMeetingCodexSession.liveTranscriptFilename, contentType: "text/markdown; charset=utf-8")
        case "/handoff", "/codex-handoff.md":
            return fileResponse(filename: LiveMeetingCodexSession.handoffFilename, contentType: "text/markdown; charset=utf-8")
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
        let session = LiveMeetingCodexSession(workspaceRoot: workspaceURL, fileManager: fileManager)
        try? session.ensureWorkspaceFiles()

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

    private func parseRequest(_ requestText: String) -> (method: String, path: String) {
        let firstLine = requestText
            .split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let rawTarget = parts.dropFirst().first.map(String.init) ?? "/"

        let targetPath: String
        if let components = URLComponents(string: rawTarget), components.scheme != nil {
            targetPath = components.path.isEmpty ? "/" : components.path
        } else {
            targetPath = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        }

        return (
            method: method.uppercased(),
            path: targetPath.removingPercentEncoding ?? targetPath
        )
    }

    private func httpResponse(status: String, contentType: String, body: Data) -> Data {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store, no-cache, must-revalidate\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var response = Data(header.utf8)
        response.append(body)
        return response
    }
}

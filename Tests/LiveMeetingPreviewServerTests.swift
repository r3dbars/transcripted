import Darwin
import Foundation

func testLiveMeetingPreviewServer() {
    guard #available(macOS 14.0, *) else { return }

    runSuite("LiveMeetingPreviewServer - serves only tokenized loopback preview files") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedLiveMeetingPreviewServer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = LiveMeetingCodexSession(workspaceRoot: root)
        do {
            try session.ensureWorkspaceFiles(createdAt: Date(timeIntervalSince1970: 1_765_994_400))
        } catch {
            assertTrue(false, "workspace setup should succeed: \(error)")
            return
        }

        let token: String
        do {
            token = try session.ensurePreviewAuthToken()
        } catch {
            assertTrue(false, "preview token setup should succeed: \(error)")
            return
        }
        try? "stale preview".write(to: session.previewURL, atomically: true, encoding: .utf8)

        let port = availableLoopbackPort()
        let server = LiveMeetingPreviewServer(workspaceURL: root, port: port)
        defer { server.stop() }

        do {
            let browserURL = try server.start(workspaceURL: root)
            assertTrue(
                browserURL.absoluteString.contains(":\(port)\(LiveMeetingCodexSession.previewServerPath)?token="),
                "start should return the authenticated browser URL"
            )
        } catch {
            assertTrue(false, "preview server should start on loopback: \(error)")
            return
        }

        let missingToken = sendPreviewRequest(path: "/state.json", port: port)
        assertEqual(missingToken.statusCode, 401, "state route should require a token")
        assertTrue(missingToken.body.contains("Unauthorized"), "missing token should return a terse body")

        let badToken = sendPreviewRequest(path: "/state.json?token=wrong", port: port)
        assertEqual(badToken.statusCode, 401, "state route should reject the wrong token")

        let badHost = sendPreviewRequest(path: "/state.json?token=\(token)", port: port, host: "example.com")
        assertEqual(badHost.statusCode, 403, "preview server should reject non-loopback Host headers")

        let state = sendPreviewRequest(path: "/state.json?token=\(token)", port: port)
        assertEqual(state.statusCode, 200, "authorized state route should be readable")
        assertTrue(state.body.contains("\"status\" : \"idle\""), "state route should serve the workspace state JSON")

        let preview = sendPreviewRequest(path: "\(LiveMeetingCodexSession.previewServerPath)?token=\(token)", port: port)
        assertEqual(preview.statusCode, 200, "authorized preview route should be readable")
        assertTrue(preview.body.contains("<!doctype html>"), "preview route should serve HTML")
        assertTrue(preview.body.contains("Status: idle"), "preview HTML should include the current sidecar state")
        assertFalse(preview.body.contains("stale preview"), "server start should refresh a stale preview file")
        assertTrue(preview.body.contains("Live Transcript"), "preview HTML should serve the clear live transcript UI")

        let transcript = sendPreviewRequest(path: "/live_transcript.md?token=\(token)", port: port)
        assertEqual(transcript.statusCode, 200, "authorized transcript route should be readable")
        assertTrue(transcript.body.contains("Status: idle"), "transcript route should serve the live transcript file")

        let post = sendPreviewRequest(path: "/state.json?token=\(token)", method: "POST", port: port)
        assertEqual(post.statusCode, 405, "preview server should reject mutating methods")

        let favicon = sendPreviewRequest(path: "/favicon.ico", port: port)
        assertEqual(favicon.statusCode, 204, "favicon route should stay harmless without a token")
    }
}

private struct PreviewHTTPResponse {
    let statusCode: Int
    let body: String
}

private func sendPreviewRequest(
    path: String,
    method: String = "GET",
    port: UInt16,
    host: String? = nil
) -> PreviewHTTPResponse {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
        return PreviewHTTPResponse(statusCode: -1, body: "socket failed")
    }
    defer { close(fd) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    _ = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)

    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        return PreviewHTTPResponse(statusCode: -1, body: "connect failed")
    }

    let request = """
    \(method) \(path) HTTP/1.1\r
    Host: \(host ?? "127.0.0.1:\(port)")\r
    Connection: close\r
    \r
    """
    let requestData = Array(request.utf8)
    let sent = requestData.withUnsafeBytes { buffer in
        Darwin.send(fd, buffer.baseAddress, buffer.count, 0)
    }
    guard sent == requestData.count else {
        return PreviewHTTPResponse(statusCode: -1, body: "send failed")
    }

    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.recv(fd, &buffer, buffer.count, 0)
        if count <= 0 { break }
        responseData.append(contentsOf: buffer.prefix(count))
    }

    let responseText = String(decoding: responseData, as: UTF8.self)
    let statusLine = responseText
        .split(separator: "\n", maxSplits: 1)
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let statusCode = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? -1
    let body = responseText.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
    return PreviewHTTPResponse(statusCode: statusCode, body: body)
}

private func availableLoopbackPort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return 0 }
    defer { close(fd) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    _ = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)

    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { return 0 }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.getsockname(fd, socketAddress, &length)
        }
    }
    guard named == 0 else { return 0 }

    return UInt16(bigEndian: boundAddress.sin_port)
}

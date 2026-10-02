import Foundation
import Darwin

func testCompanionSocket() {
    runSuite("Companion exposes a private authenticated local endpoint and removes it on disconnect") {
        let root = companionFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("companion", isDirectory: true)
        let server = CompanionSocketServer(directory: directory)
        defer { server.stop() }
        var stage = "open endpoint"
        do {
            try server.start { request, reply in
                reply(CompanionProtocol.response(id: request.id, result: ["fixture": true]))
            }
            stage = "read connection"
            let connectionURL = directory.appendingPathComponent("connection.json")
            let connection = try JSONSerialization.jsonObject(with: Data(contentsOf: connectionURL)) as! [String: Any]
            assertEqual(connection["protocol_version"] as? Int, 1)
            assertTrue((connection["token"] as? String)?.count == 64, "the credential has 256 bits of randomness")
            assertEqual(companionFixtureMode(directory), 0o700)
            assertEqual(companionFixtureMode(connectionURL), 0o600)
            assertEqual(companionFixtureMode(directory.appendingPathComponent("s")), 0o600)
            let id = UUID()
            stage = "authenticated exchange"
            let reply = try companionFixtureExchange(connection, request: ["version": 1, "id": id.uuidString,
                "method": "status", "params": [:], "token": connection["token"]!])
            assertEqual(reply["id"] as? String, id.uuidString)
            assertEqual(reply["ok"] as? Bool, true)
            stage = "authentication refusal"
            let refusedID = UUID()
            let refused = try companionFixtureExchange(connection, request: ["version": 1, "id": refusedID.uuidString,
                "method": "status", "params": [:], "token": "wrong-fixture-token"])
            assertEqual(refused["id"] as? String, refusedID.uuidString)
            assertEqual(refused["ok"] as? Bool, false)
            assertEqual((refused["error"] as? [String: String])?["code"], "auth_failed")
            server.stop()
            assertFalse(FileManager.default.fileExists(atPath: connectionURL.path))
            assertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("s").path))
        } catch {
            let category = error is CompanionSocketError ? String(describing: error) : "fixture_io"
            assertTrue(false, "The isolated companion fixture failed at \(stage): \(category).")
        }
    }

    runSuite("Companion refuses a symlinked directory and leaves its target alone") {
        let root = companionFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("target", isDirectory: true)
        try! FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent("companion", isDirectory: true)
        try! FileManager.default.createSymbolicLink(at: directory, withDestinationURL: destination)
        let server = CompanionSocketServer(directory: directory)
        defer { server.stop() }
        var refused = false
        do { try server.start { _, _ in } } catch { refused = true }
        assertTrue(refused)
        assertTrue((try! FileManager.default.contentsOfDirectory(atPath: destination.path)).isEmpty)
    }

    runSuite("Companion refuses public directories and symlinked connection files") {
        let root = companionFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("companion", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = chmod(directory.path, 0o755)
        let server = CompanionSocketServer(directory: directory)
        defer { server.stop() }
        var refused = false
        do { try server.start { _, _ in } } catch { refused = true }
        assertTrue(refused)
        _ = chmod(directory.path, 0o700)
        let target = root.appendingPathComponent("untouched.json")
        try! Data("fixture".utf8).write(to: target)
        try! FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("connection.json"), withDestinationURL: target)
        refused = false
        do { try server.start { _, _ in } } catch { refused = true }
        assertTrue(refused)
        assertTrue((try! Data(contentsOf: target)) == Data("fixture".utf8))
    }
}

private func companionFixtureDirectory() -> URL {
    // Foundation normalizes macOS /private/var back to the /var symlink even
    // after resolvingSymlinksInPath; choose the real temporary parent directly.
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("tcc-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}

private func companionFixtureMode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
}

private func companionFixtureExchange(_ connection: [String: Any], request: [String: Any]) throws -> [String: Any] {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CompanionSocketError.unavailable }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let path = Array((connection["socket_path"] as! String).utf8) + [0]
    guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CompanionSocketError.pathTooLong }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { throw CompanionSocketError.unavailable }
    let data = try JSONSerialization.data(withJSONObject: request) + Data([10])
    let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    guard written == data.count else { throw CompanionSocketError.unavailable }
    var response = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    while response.last != 10 {
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0, response.count < CompanionProtocol.maximumResponseBytes else { throw CompanionSocketError.unavailable }
        response.append(contentsOf: bytes.prefix(count))
    }
    return try JSONSerialization.jsonObject(with: response) as! [String: Any]
}

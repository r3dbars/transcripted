import CryptoKit
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class ModelDownloadServiceTests: XCTestCase {
    override func tearDown() {
        URLProtocol.unregisterClass(ModelDownloadURLProtocol.self)
        ModelDownloadURLProtocol.reset()
        super.tearDown()
    }

    func testSafeModelFilenameAllowsNestedModelFiles() {
        XCTAssertTrue(ModelDownloadService.isSafeModelFilename("config.json"))
        XCTAssertTrue(ModelDownloadService.isSafeModelFilename("onnx/model.onnx"))
        XCTAssertTrue(ModelDownloadService.isSafeModelFilename("snapshots/abc123/model.safetensors"))
    }

    func testSafeModelFilenameRejectsEscapesAndControlCharacters() {
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename(""))
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("/config.json"))
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("../secret"))
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("weights/../secret"))
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("weights/./config.json"))
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("config\n.json"))
    }

    func testSHA256HexStreamsFileContents() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("fixture.bin")
        try Data("abc".utf8).write(to: fileURL)

        XCTAssertEqual(
            try ModelDownloadService.sha256Hex(of: fileURL),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testClassifyErrorMapsOfflineURLErrors() {
        let errors: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .dataNotAllowed,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed
        ]

        for code in errors {
            XCTAssertEqual(ModelDownloadService.classifyError(URLError(code)), .networkOffline)
        }
        XCTAssertEqual(DownloadErrorKind.networkOffline.title, "No Internet Connection")
        XCTAssertEqual(DownloadErrorKind.networkOffline.detail, "Connect to the internet and try again.")
    }

    func testClassifyErrorMapsTLSAndTimeoutURLErrors() {
        XCTAssertEqual(
            ModelDownloadService.classifyError(URLError(.secureConnectionFailed)),
            .tlsFailure
        )
        XCTAssertEqual(
            ModelDownloadService.classifyError(URLError(.serverCertificateUntrusted)),
            .tlsFailure
        )
        XCTAssertEqual(
            ModelDownloadService.classifyError(URLError(.timedOut)),
            .timeout
        )
    }

    func testClassifyErrorMapsDiskSpaceBeforeGenericFallback() {
        XCTAssertEqual(
            ModelDownloadService.classifyError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)),
            .diskSpace
        )
        XCTAssertEqual(
            ModelDownloadService.classifyError(NSError(domain: NSPOSIXErrorDomain, code: 28)),
            .diskSpace
        )
    }

    func testClassifyErrorPreservesUnknownLocalizedDescription() {
        let error = NSError(
            domain: "ModelDownloadServiceTests",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "fixture download failed"]
        )

        XCTAssertEqual(
            ModelDownloadService.classifyError(error),
            .unknown("fixture download failed")
        )
    }

    func testFetchModelFileListReadsSafeManifestFromHuggingFace() async throws {
        installModelDownloadURLProtocol(statusCode: 200, body: """
        {
          "siblings": [
            { "rfilename": "config.json", "size": 123 },
            {
              "rfilename": "model.safetensors",
              "size": 456,
              "lfs": { "sha256": "abcdef123456" }
            }
          ]
        }
        """)

        let files = try await ModelDownloadService.fetchModelFileList(modelId: "org/test-model")

        XCTAssertEqual(ModelDownloadURLProtocol.requestedURLs().compactMap(\.host), ["huggingface.co"])
        XCTAssertEqual(ModelDownloadURLProtocol.requestedURLs().first?.path, "/api/models/org/test-model")
        XCTAssertEqual(files.map(\.name), ["config.json", "model.safetensors"])
        XCTAssertEqual(files.map(\.size), [123, 456])
        XCTAssertEqual(files.map(\.sha256), [nil, "abcdef123456"])
    }

    func testFetchModelFileListSkipsUnsafeManifestFilenames() async throws {
        installModelDownloadURLProtocol(statusCode: 200, body: """
        {
          "siblings": [
            { "rfilename": "../escape.bin", "size": 1 },
            { "rfilename": "nested/./escape.bin", "size": 2 },
            { "rfilename": "safe/model.bin", "size": 3, "lfs": { "sha256": "feedface" } }
          ]
        }
        """)

        let files = try await ModelDownloadService.fetchModelFileList(modelId: "org/test-model")

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.name, "safe/model.bin")
        XCTAssertEqual(files.first?.size, 3)
        XCTAssertEqual(files.first?.sha256, "feedface")
    }

    func testFetchModelFileListFailsClosedOnServerErrorWithoutMirrorFallback() async {
        installModelDownloadURLProtocol(statusCode: 503, body: #"{"error":"unavailable"}"#)

        do {
            _ = try await ModelDownloadService.fetchModelFileList(modelId: "org/test-model")
            XCTFail("Expected manifest fetch to fail closed")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error.kind, .unknown("Could not fetch model file list from any mirror"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestedHosts = ModelDownloadURLProtocol.requestedURLs().compactMap(\.host)
        XCTAssertEqual(requestedHosts, ["huggingface.co"])
        XCTAssertFalse(requestedHosts.contains("hf-mirror.com"))
    }

    func testFetchModelFileListFailsClosedOnMalformedManifest() async {
        installModelDownloadURLProtocol(statusCode: 200, body: #"{"siblings":"not-an-array"}"#)

        do {
            _ = try await ModelDownloadService.fetchModelFileList(modelId: "org/test-model")
            XCTFail("Expected malformed manifest to fail closed")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error.kind, .unknown("Could not fetch model file list from any mirror"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(ModelDownloadURLProtocol.requestedURLs().compactMap(\.host), ["huggingface.co"])
    }

    func testDownloadFileWithMirrorFallbackWritesVerifiedFileFromHuggingFace() async throws {
        let body = Data("trusted model bytes".utf8)
        installModelDownloadURLProtocol(statusCode: 200, data: body)
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let destination = tempRoot.appendingPathComponent("model.safetensors")

        try await ModelDownloadService.downloadFileWithMirrorFallback(
            modelId: "org/test-model",
            filename: "model.safetensors",
            destination: destination,
            expectedSHA256: sha256Hex(for: body).uppercased()
        )

        XCTAssertEqual(try Data(contentsOf: destination), body)
        XCTAssertEqual(ModelDownloadURLProtocol.requestedURLs().compactMap(\.host), ["huggingface.co"])
        XCTAssertEqual(
            ModelDownloadURLProtocol.requestedURLs().first?.path,
            "/org/test-model/resolve/main/model.safetensors"
        )
        let permissions = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testDownloadFileWithMirrorFallbackAllowsNonLFSFileWithoutDigest() async throws {
        let body = Data(#"{"model":"config"}"#.utf8)
        installModelDownloadURLProtocol(statusCode: 200, data: body)
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let destination = tempRoot.appendingPathComponent("config.json")

        try await ModelDownloadService.downloadFileWithMirrorFallback(
            modelId: "org/test-model",
            filename: "config.json",
            destination: destination
        )

        XCTAssertEqual(try Data(contentsOf: destination), body)
        XCTAssertEqual(ModelDownloadURLProtocol.requestedURLs().compactMap(\.host), ["huggingface.co"])
    }

    func testDownloadFileWithMirrorFallbackRejectsDigestMismatchAndCleansDestination() async throws {
        installModelDownloadURLProtocol(statusCode: 200, data: Data("tampered model bytes".utf8))
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let destination = tempRoot.appendingPathComponent("model.safetensors")

        do {
            try await ModelDownloadService.downloadFileWithMirrorFallback(
                modelId: "org/test-model",
                filename: "model.safetensors",
                destination: destination,
                expectedSHA256: sha256Hex(for: Data("trusted model bytes".utf8))
            )
            XCTFail("Expected digest mismatch to fail")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error.kind, .unknown("Failed to download model.safetensors from all mirrors"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestedHosts = ModelDownloadURLProtocol.requestedURLs().compactMap(\.host)
        XCTAssertTrue(requestedHosts.allSatisfy { $0 == "huggingface.co" })
        XCTAssertFalse(requestedHosts.contains("hf-mirror.com"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDownloadFileWithMirrorFallbackFailsClosedOnServerErrorWithoutMirrorFallback() async throws {
        installModelDownloadURLProtocol(statusCode: 503, data: Data("unavailable".utf8))
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let destination = tempRoot.appendingPathComponent("model.safetensors")

        do {
            try await ModelDownloadService.downloadFileWithMirrorFallback(
                modelId: "org/test-model",
                filename: "model.safetensors",
                destination: destination,
                expectedSHA256: sha256Hex(for: Data("trusted model bytes".utf8))
            )
            XCTFail("Expected server error to fail closed")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error.kind, .unknown("Failed to download model.safetensors from all mirrors"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestedHosts = ModelDownloadURLProtocol.requestedURLs().compactMap(\.host)
        XCTAssertTrue(requestedHosts.allSatisfy { $0 == "huggingface.co" })
        XCTAssertFalse(requestedHosts.contains("hf-mirror.com"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testWithRetryDoesNotRetryDiskSpaceFailures() async {
        var attempts = 0

        do {
            _ = try await ModelDownloadService.withRetry(maxAttempts: 3) {
                attempts += 1
                throw NSError(domain: NSPOSIXErrorDomain, code: 28)
            } as String
            XCTFail("Expected disk space failure")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error.kind, .diskSpace)
            XCTAssertEqual(attempts, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWithRetryRejectsZeroAttemptsWithoutRunningOperation() async {
        var attempts = 0

        do {
            _ = try await ModelDownloadService.withRetry(maxAttempts: 0) {
                attempts += 1
                return "should-not-run"
            }
            XCTFail("Expected zero-attempt guard failure")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(
                error.kind,
                .unknown("No download was attempted (maxAttempts was 0)")
            )
            XCTAssertNil(error.underlyingError)
            XCTAssertEqual(attempts, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeTempRoot() throws -> URL {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        return tempRoot
    }

    private func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func installModelDownloadURLProtocol(statusCode: Int, body: String) {
        installModelDownloadURLProtocol(statusCode: statusCode, data: Data(body.utf8), contentType: "application/json")
    }

    private func installModelDownloadURLProtocol(
        statusCode: Int,
        data: Data,
        contentType: String = "application/octet-stream"
    ) {
        ModelDownloadURLProtocol.reset()
        ModelDownloadURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": contentType]
            ))
            return (response, data)
        }
        _ = URLProtocol.registerClass(ModelDownloadURLProtocol.self)
    }
}

@available(macOS 14.0, *)
private final class ModelDownloadURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    private static let lock = NSLock()
    private static var urls: [URL] = []

    static func reset() {
        lock.lock()
        handler = nil
        urls = []
        lock.unlock()
    }

    static func requestedURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "huggingface.co" || host == "hf-mirror.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        if let url = request.url {
            Self.urls.append(url)
        }
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

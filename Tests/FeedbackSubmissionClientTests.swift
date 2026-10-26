import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
func testFeedbackSubmissionClient() async {
    runSuite("Feedback validates the message and optional reply address before sending") {
        for message in ["", " \n\t ", String(repeating: "x", count: 4_001)] {
            var draft = feedbackTestDraft()
            draft.message = message
            feedbackExpectError(.invalidMessage) { try draft.validate() }
        }
        for email in ["person", "@example.com", "person@", "person@example.com\r\nBcc:victim@example.com", "a@.com", "a@x.", "person@exämple.com", "person@exam,ple.com", String(repeating: "x", count: 250) + "@example.com"] {
            var draft = feedbackTestDraft()
            draft.replyEmail = email
            feedbackExpectError(.invalidEmail) { try draft.validate() }
        }
        for email in ["", "person+reply@example.com"] {
            var draft = feedbackTestDraft()
            draft.replyEmail = email
            do { try draft.validate() }
            catch { assertTrue(false, "optional or ordinary email should be accepted") }
        }
        var exactLimit = feedbackTestDraft()
        exactLimit.message = String(repeating: "x", count: 4_000)
        do { try exactLimit.validate() }
        catch { assertTrue(false, "a message at the documented boundary should be accepted") }
    }

    runSuite("Feedback sends only the reviewed content to the fixed support endpoint") {
        var draft = feedbackTestDraft()
        draft.message = " \nThe button was difficult to find. \n"
        draft.replyEmail = " person@example.com "
        do {
            let first = try FeedbackSubmissionClient.request(for: draft)
            let second = try FeedbackSubmissionClient.request(for: draft)
            assertEqual(first.url?.absoluteString, "https://transcripted.app/api/feedback", "the destination is fixed")
            assertEqual(first.httpMethod, "POST", "feedback uses an explicit submission")
            assertEqual(first.value(forHTTPHeaderField: "Content-Type"), "application/json", "request format is explicit")
            assertEqual(first.value(forHTTPHeaderField: "Idempotency-Key"), draft.id.uuidString, "retry key belongs to this reviewed draft")
            assertEqual(first.value(forHTTPHeaderField: "Idempotency-Key"), second.value(forHTTPHeaderField: "Idempotency-Key"), "unchanged retries retain the same key")
            let body = try JSONSerialization.jsonObject(with: first.httpBody ?? Data()) as? [String: Any]
            let retryBody = try JSONSerialization.jsonObject(with: second.httpBody ?? Data()) as? NSDictionary
            assertEqual(body.map { $0 as NSDictionary }, retryBody, "unchanged retries contain the same reviewed payload")
            assertNil(body?["diagnostics"], "opting out omits diagnostics completely")
            assertEqual(body?["message"] as? String, "The button was difficult to find.", "message is normalized before encoding")
            assertEqual(body?["replyEmail"] as? String, "person@example.com", "optional reply address is normalized")
            assertEqual((body?["attachments"] as? [[String: Any]])?.count, 0, "unselected images are never included")
            assertNil(body?["recipient"], "the client cannot choose a mail recipient")

            let selected = feedbackTestJPEG()
            draft.attachments = [selected]
            draft.diagnostics = FeedbackDiagnostics(osVersion: "macOS synthetic", buildRevision: "abc123")
            let withAttachment = try FeedbackSubmissionClient.request(for: draft)
            let selectedBody = try JSONSerialization.jsonObject(with: withAttachment.httpBody ?? Data()) as? [String: Any]
            let images = selectedBody?["attachments"] as? [[String: Any]]
            assertEqual(images?.count, 1, "only the selected screenshot is attached")
            assertEqual(images?.first?["data"] as? String, selected.data.base64EncodedString(), "the reviewed screenshot bytes are sent")
            let diagnostics = selectedBody?["diagnostics"] as? [String: Any]
            assertEqual(Set(diagnostics?.keys.map { $0 } ?? []), Set(["osVersion", "buildRevision"]), "diagnostics contain only the reviewed schema")
        } catch { assertTrue(false, "valid reviewed content should produce a request") }
    }

    runSuite("Feedback attachment count size format and filenames are bounded") {
        let valid = feedbackTestJPEG()
        var draft = feedbackTestDraft()
        draft.attachments = [valid, feedbackTestJPEG(), feedbackTestJPEG()]
        do { try draft.validate() }
        catch { assertTrue(false, "three small selected screenshots should be accepted") }
        draft.attachments.append(feedbackTestJPEG())
        feedbackExpectError(.tooManyAttachments) { try draft.validate() }

        let excessive = FeedbackAttachment(id: valid.id, data: Data(repeating: 0, count: FeedbackAttachment.maximumBytes + 1), mimeType: valid.mimeType, filename: valid.filename)
        feedbackExpectError(.imageTooLarge) { try excessive.validate() }
        let unsafeName = FeedbackAttachment(id: valid.id, data: valid.data, mimeType: valid.mimeType, filename: "private-folder-name.jpg")
        feedbackExpectError(.unsupportedImage) { try unsafeName.validate() }
        let notAnImage = FeedbackAttachment(id: valid.id, data: Data("<script>no</script>".utf8), mimeType: "image/jpeg", filename: valid.filename)
        feedbackExpectError(.unsupportedImage) { try notAnImage.validate() }
        let wrongMIME = FeedbackAttachment(id: valid.id, data: valid.data, mimeType: "text/html", filename: valid.filename)
        feedbackExpectError(.unsupportedImage) { try wrongMIME.validate() }
    }

    runSuite("Optional feedback logs accept only three bounded categorical entries") {
        let valid = FeedbackLogEntry(kind: "capture_timeout", stage: "recording", version: "1.1.73")
        assertTrue(valid.isValid, "safe categories can be included after explicit review")
        var draft = feedbackTestDraft()
        draft.diagnostics = FeedbackDiagnostics(osVersion: "macOS synthetic", buildRevision: "abc123", logs: [valid, valid, valid])
        do {
            let request = try FeedbackSubmissionClient.request(for: draft)
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let diagnostics = body?["diagnostics"] as? [String: Any]
            let logs = diagnostics?["logs"] as? [[String: Any]]
            assertEqual(logs?.count, 3, "the reviewed entries are encoded")
            assertEqual(Set(logs?.first?.keys.map { $0 } ?? []), Set(["kind", "stage", "version"]), "log entries cannot carry raw lines, timestamps, identifiers, or paths")
            assertEqual(logs?.first?["kind"] as? String, valid.kind, "wire categories match the reviewed values")
            assertTrue(draft.copyText.contains(valid.preview), "the complete copy fallback includes the same chosen categories")
        } catch { assertTrue(false, "valid categorical logs should encode") }
        draft.diagnostics = FeedbackDiagnostics(osVersion: "macOS synthetic", buildRevision: "abc123", logs: [valid, valid, valid, valid])
        feedbackExpectError(.invalidReport) { try draft.validate() }
        for unsafe in ["", "two words", "timeout\n", "timeout\r", "/Users/private", "person@example.com", "https://example.com", "päätös", String(repeating: "x", count: 81)] {
            for entry in [FeedbackLogEntry(kind: unsafe, stage: valid.stage, version: valid.version),
                          FeedbackLogEntry(kind: valid.kind, stage: unsafe, version: valid.version),
                          FeedbackLogEntry(kind: valid.kind, stage: valid.stage, version: unsafe)] {
                assertFalse(entry.isValid, "every log field rejects unsafe values")
                draft.diagnostics = FeedbackDiagnostics(osVersion: "macOS synthetic", buildRevision: "abc123", logs: [entry])
                feedbackExpectError(.invalidReport) { try draft.validate() }
            }
        }
    }

    await runSuite("Selected screenshots are resized and reencoded without source metadata") {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcripted-feedback-test-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let selected = directory.appendingPathComponent("synthetic-private-title.png")
            let marker = "Synthetic private author marker"
            try feedbackSyntheticPNG(width: 2_000, height: 1_000, author: marker).write(to: selected)
            let attachment = try await FeedbackAttachment.load(from: selected)
            try attachment.validate()
            assertEqual(attachment.mimeType, "image/jpeg", "attachments are reencoded into the supported output format")
            assertFalse(attachment.filename.contains("private"), "source filenames do not leave the Mac")
            assertTrue(attachment.data.count <= FeedbackAttachment.maximumBytes, "encoded output respects the transport limit")
            let source = CGImageSourceCreateWithData(attachment.data as CFData, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            assertTrue(width > 0 && height > 0 && max(width, height) <= 1_600, "normalization bounds image dimensions")
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary
            assertNil(tiff?[kCGImagePropertyTIFFArtist], "source author metadata is not copied")
            assertNil(attachment.data.range(of: Data(marker.utf8)), "private source metadata is absent from encoded bytes")

            let unsupported = directory.appendingPathComponent("not-a-screenshot.png")
            try Data("not an image".utf8).write(to: unsupported)
            do {
                _ = try await FeedbackAttachment.load(from: unsupported)
                assertTrue(false, "a filename alone must never make arbitrary bytes into an attachment")
            } catch { assertEqual(error as? FeedbackSubmissionError, .unsupportedImage, "unsupported contents fail safely") }
        } catch { assertTrue(false, "synthetic screenshot normalization failed: \(error)") }
    }

    await runSuite("Feedback confirms acceptance only for a matching receipt") {
        let draft = feedbackTestDraft()
        let accepted = FeedbackSubmissionClient(transport: { request in
            let receipt = FeedbackReceipt(id: draft.id.uuidString, status: "accepted")
            return (try JSONEncoder().encode(receipt), feedbackResponse(request, code: 200))
        })
        do {
            let receipt = try await accepted.send(draft)
            assertEqual(receipt.id, draft.id.uuidString, "the accepted receipt identifies this report")
        } catch { assertTrue(false, "matching server acceptance should succeed") }

        for (code, payload, expected) in [
            (302, "", FeedbackSubmissionError.rejected),
            (200, "not-json", .rejected),
            (200, "{\"id\":\"\(UUID().uuidString)\",\"status\":\"accepted\"}", .rejected),
            (200, "{\"id\":\"\(draft.id.uuidString)\",\"status\":\"queued\"}", .rejected),
            (409, "", .uncertain), (429, "", .rateLimited), (503, "", .unavailable)
        ] {
            let client = FeedbackSubmissionClient(transport: { request in
                (Data(payload.utf8), feedbackResponse(request, code: code))
            })
            do {
                _ = try await client.send(draft)
                assertTrue(false, "response \(code) must not claim feedback was sent")
            } catch { assertEqual(error as? FeedbackSubmissionError, expected, "response status has a safe user-facing result") }
        }
        let unavailable = FeedbackSubmissionClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await unavailable.send(draft)
            assertTrue(false, "a transport failure cannot become sent")
        } catch { assertEqual(error as? FeedbackSubmissionError, .unavailable, "network errors do not leak request details") }
        let cancelled = FeedbackSubmissionClient(transport: { _ in throw CancellationError() })
        do {
            _ = try await cancelled.send(draft)
            assertTrue(false, "cancellation cannot be reported as sent")
        } catch { assertTrue(error is CancellationError, "cancellation remains cancellation for the composer") }
    }

    runSuite("Copied feedback includes the complete message without pretending screenshots were copied") {
        var draft = feedbackTestDraft()
        draft.attachments = [feedbackTestJPEG()]
        draft.diagnostics = FeedbackDiagnostics(osVersion: "macOS synthetic", buildRevision: "abc123")
        assertTrue(draft.copyText.contains(draft.message), "copy fallback retains the actual user message")
        assertTrue(draft.copyText.contains(draft.id.uuidString), "support can match the report ID")
        assertTrue(draft.copyText.contains("attach these separately"), "text copy does not claim to include image files")
        assertTrue(draft.copyText.contains("macOS synthetic"), "only opted-in diagnostics appear in copied feedback")
    }
}

private func feedbackTestDraft() -> FeedbackDraft {
    FeedbackDraft(message: "The button was difficult to find.", replyEmail: "", appVersion: "1.1.73", diagnostics: nil)
}

private func feedbackTestJPEG() -> FeedbackAttachment {
    let id = UUID()
    return FeedbackAttachment(id: id, data: Data([255, 216, 255, 0, 255, 217]), mimeType: "image/jpeg", filename: "screenshot-\(id.uuidString).jpg")
}

private func feedbackExpectError(_ expected: FeedbackSubmissionError, operation: () throws -> Void) {
    do {
        try operation()
        assertTrue(false, "expected the report to be rejected with \(expected)")
    } catch { assertEqual(error as? FeedbackSubmissionError, expected, "rejected feedback gives the expected validation result") }
}

private func feedbackResponse(_ request: URLRequest, code: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
}

private func feedbackSyntheticPNG(width: Int, height: Int, author: String) throws -> Data {
    let data = Data(repeating: 160, count: width * height * 4)
    let provider = CGDataProvider(data: data as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: author]] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw FeedbackSubmissionError.unsupportedImage }
    return output as Data
}

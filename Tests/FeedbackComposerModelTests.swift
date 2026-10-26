import Foundation
import AppKit
import Combine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
func testFeedbackComposerModel() async {
    let diagnostics = FeedbackDiagnostics(osVersion: "Synthetic macOS", buildRevision: "synthetic-revision")
    var deliveries: [FeedbackDraft] = []
    let model = FeedbackComposerModel(appVersion: "synthetic", diagnostics: diagnostics, sender: { draft in
        deliveries.append(draft)
        throw FeedbackSubmissionError.unavailable
    })

    runSuite("Feedback cannot send before a person writes and reviews a report") {
        assertFalse(model.canReview, "a blank report has no enabled review action")
        model.review()
        assertTrue(model.step == .compose, "a blank report remains editable")
    }
    await model.send()
    assertEqual(deliveries.count, 0, "send cannot bypass review")

    model.message = String(repeating: "😀", count: 2_001)
    assertFalse(model.canReview, "supplementary characters count toward the same server length boundary")
    model.message = String(repeating: "😀", count: 2_000)
    assertTrue(model.canReview, "a message exactly at the UTF-16 boundary can be reviewed")
    model.message = ""

    model.open(area: "meetings")
    model.message = "The review was confusing."
    model.replyEmail = "not-an-email"
    model.review()
    assertTrue(model.step == .compose, "an invalid reply address is caught before review")
    assertNotNil(model.errorMessage, "validation tells the person what to fix")
    model.replyEmail = ""
    model.review()
    assertTrue(model.step == .review, "a valid anonymous report reaches review")
    await model.send()

    runSuite("An unavailable service preserves the reviewed report and its privacy choices") {
        assertTrue(model.step == .review, "failure never renders the success screen")
        assertEqual(model.message, "The review was confusing.", "the message survives failure")
        assertEqual(model.area, "meetings", "the context survives failure")
        assertNotNil(model.errorMessage, "failure stays visible")
        assertFalse(model.isSending, "a failed attempt unlocks the controls")
        assertEqual(deliveries.count, 1, "one Send press creates one attempt")
        assertNil(deliveries.first?.diagnostics, "diagnostics default to off")
        assertEqual(deliveries.first?.attachments.count, 0, "no screenshots are attached automatically")
    }

    await model.send()
    assertEqual(deliveries[0].id, deliveries[1].id, "a retry keeps its receipt identity")
    model.edit()
    model.review()
    await model.send()
    assertEqual(deliveries[1].id, deliveries[2].id, "Back then Review without edits keeps its receipt identity")
    model.edit()
    model.message = "The naming review was confusing."
    model.review()
    await model.send()
    assertFalse(deliveries[2].id == deliveries[3].id, "changing the message creates a new report")
    model.edit()
    model.replyEmail = "person@example.com"
    model.includeDiagnostics = true
    model.review()
    await model.send()
    assertFalse(deliveries[3].id == deliveries[4].id, "changed email and diagnostic consent create a new report")
    assertEqual(deliveries.last?.diagnostics, diagnostics, "opting in includes only the supplied safe diagnostic schema")
    model.open(area: "general")
    assertEqual(model.area, "meetings", "reopening does not silently change a reviewed report's context")

    let safePicker = FeedbackComposerModel(appVersion: "synthetic", diagnostics: diagnostics)
    safePicker.addScreenshots([URL(string: "https://example.com/private.png")!])
    assertFalse(safePicker.isLoadingAttachments, "a dropped network URL is never fetched")
    assertNotNil(safePicker.errorMessage, "a dropped network URL gets a useful explanation")
    safePicker.addScreenshots((0..<4).map { URL(fileURLWithPath: "/synthetic/\($0).png") })
    assertFalse(safePicker.isLoadingAttachments, "too many selected screenshots are rejected before file reads")

    var successCalls = 0
    weak var pendingModel: FeedbackComposerModel?
    let successful = FeedbackComposerModel(appVersion: "synthetic", diagnostics: diagnostics, sender: { draft in
        successCalls += 1
        assertTrue(pendingModel?.isSending == true, "sending state is visible while transport is pending")
        assertFalse(pendingModel?.canReview ?? true, "review cannot restart while transport is pending")
        if let pendingModel {
            await pendingModel.send()
        }
        return FeedbackReceipt(id: draft.id.uuidString, status: "accepted")
    })
    pendingModel = successful
    successful.message = "The screenshot picker is easy to use."
    successful.review()
    await successful.send()
    runSuite("A confirmed delivery alone shows success and prevents duplicate submission") {
        assertTrue(successful.step == .sent, "a confirmed receipt reaches success")
        assertNotNil(successful.receiptID, "the person receives a reference")
        assertFalse(successful.isSending, "success clears the progress indicator")
        assertEqual(successCalls, 1, "a second Send while pending cannot create another request")
    }
    await successful.send()
    assertEqual(successCalls, 1, "sending from the success screen cannot duplicate a report")
    successful.reset()
    assertTrue(successful.step == .compose, "Write another starts an editable report")
    assertEqual(successful.message, "", "Write another clears the previous text")
    assertEqual(successful.replyEmail, "", "Write another clears the previous address")
    assertFalse(successful.includeDiagnostics, "a new report requires fresh diagnostic consent")
    await feedbackScreenshotProviderSuites()
    await feedbackDropTransferSuites()
    await feedbackDiagnosticConsentSuites()
}

@MainActor
private func feedbackDiagnosticConsentSuites() async {
    await runSuite("Feedback logs are read only on opt in and stay identical from preview through sending") {
        let first = FeedbackLogEntry(kind: "capture_timeout", stage: "recording", version: "1.1.73")
        let second = FeedbackLogEntry(kind: "paste_unconfirmed", stage: "delivery", version: "1.1.73")
        let third = FeedbackLogEntry(kind: "model_unavailable", stage: "transcription", version: "1.1.72")
        let fourth = FeedbackLogEntry(kind: "another_failure", stage: "unknown", version: "1.1.71")
        let newer = FeedbackLogEntry(kind: "new_failure", stage: "startup", version: "1.1.74")
        var available = [FeedbackLogEntry(kind: "/synthetic/private-path", stage: "recording", version: "1.1.73"), first, second, third, fourth]
        var providerReads = 0
        var sent: [FeedbackDraft] = []
        let model = FeedbackComposerModel(
            appVersion: "synthetic",
            diagnostics: FeedbackDiagnostics(osVersion: "Synthetic macOS", buildRevision: "synthetic"),
            logsProvider: { providerReads += 1; return available },
            sender: { draft in sent.append(draft); throw FeedbackSubmissionError.unavailable }
        )
        model.message = "The recording stopped unexpectedly."
        assertFalse(model.includeDiagnostics, "logs are off by default")
        assertEqual(providerReads, 0, "opening a report does not inspect the failure log")
        model.review()
        await model.send()
        assertNil(sent.last?.diagnostics, "an ordinary report carries no optional diagnostics or logs")
        assertEqual(providerReads, 0, "reviewing and sending without opt in never reads the provider")

        model.edit()
        model.includeDiagnostics = true
        assertEqual(providerReads, 1, "explicit consent takes one log snapshot")
        let approvedPreview = model.diagnosticPreview
        for entry in [first, second, third] {
            assertTrue(approvedPreview.contains(entry.preview), "preview contains each included category")
        }
        assertFalse(approvedPreview.contains(fourth.preview), "preview caps the snapshot at three valid entries")
        assertFalse(approvedPreview.contains("private-path"), "invalid categories never enter the preview")
        available = [newer]
        model.review()
        assertEqual(model.diagnosticPreview, approvedPreview, "review does not replace the snapshot with newer data")
        await model.send()
        assertEqual(sent.last?.diagnostics?.logs, [first, second, third], "sent logs are exactly those shown in the preview")
        assertEqual(providerReads, 1, "sending does not silently collect newer log entries")
        let firstID = sent.last?.id
        await model.send()
        assertEqual(sent.last?.id, firstID, "retry preserves report identity and snapshot")
        assertEqual(sent.last?.diagnostics?.logs, [first, second, third], "retry sends the same reviewed categories")
        assertEqual(providerReads, 1, "retry does not refresh optional logs")

        model.edit()
        model.includeDiagnostics = false
        model.review()
        await model.send()
        assertNil(sent.last?.diagnostics, "turning consent off removes the complete optional diagnostic payload")
        assertEqual(providerReads, 1, "opting out does not read again")
        model.edit()
        model.includeDiagnostics = true
        assertEqual(providerReads, 2, "a fresh opt in explicitly captures a fresh snapshot")
        assertTrue(model.diagnosticPreview.contains(newer.preview), "new consent previews the new category")
        assertFalse(model.diagnosticPreview.contains(first.preview), "the old snapshot is not retained after new consent")
        model.review()
        await model.send()
        assertEqual(sent.last?.diagnostics?.logs, [newer], "the fresh reviewed snapshot is the fresh sent payload")
        assertFalse(sent.last?.id == firstID, "changed diagnostic content gets a new idempotency identity")
    }
}

@MainActor
private func feedbackDropTransferSuites() async {
    await runSuite("A provider timeout wins once and ignores a later successful callback") {
        do {
            let _: Data = try await withCheckedThrowingContinuation { continuation in
                let transfer = FeedbackDropTransfer(continuation)
                transfer.finish(.failure(FeedbackSubmissionError.unsupportedImage))
                transfer.finish(.success(Data([1, 2, 3])))
            }
            assertTrue(false, "a late provider cannot override a timeout")
        } catch { assertEqual(error as? FeedbackSubmissionError, .unsupportedImage, "the first completion remains final") }
    }
    await runSuite("A successful provider ignores its later timeout") {
        do {
            let result: Data = try await withCheckedThrowingContinuation { continuation in
                let transfer = FeedbackDropTransfer(continuation)
                transfer.finish(.success(Data([1, 2, 3])))
                transfer.finish(.failure(FeedbackSubmissionError.unsupportedImage))
            }
            assertEqual(result, Data([1, 2, 3]), "an already loaded screenshot cannot become a timeout")
        } catch { assertTrue(false, "the late timeout must be ignored") }
    }
    await runSuite("Concurrent provider callbacks resolve the attachment transfer exactly once") {
        do {
            let result: Data = try await withCheckedThrowingContinuation { continuation in
                let transfer = FeedbackDropTransfer(continuation)
                DispatchQueue.concurrentPerform(iterations: 16) { value in
                    transfer.finish(.success(Data([UInt8(value)])))
                }
            }
            assertEqual(result.count, 1, "a racing completion produces one complete result")
            assertTrue((result.first ?? 255) < 16, "the result comes from one admitted completion")
        } catch { assertTrue(false, "a concurrent successful provider must resolve safely") }
    }
}

@MainActor
private func feedbackScreenshotProviderSuites() async {
    let diagnostics = FeedbackDiagnostics(osVersion: "Synthetic macOS", buildRevision: "synthetic")
    let model = FeedbackComposerModel(appVersion: "synthetic", diagnostics: diagnostics)
    model.message = "A screenshot is easier than describing the layout."
    do {
        let marker = "Synthetic private image author"
        let png = try feedbackProviderImage(type: UTType.png.identifier, author: marker)
        await runSuite("Image-only drops are normalized without a file URL or automatic sending") {
            let provider = feedbackDataProvider(png, type: UTType.png.identifier)
            assertTrue(model.addScreenshotProviders([provider]), "a screenshot thumbnail can supply bytes rather than a URL")
            assertTrue(model.isLoadingAttachments, "loading state starts before accepting another drop")
            assertFalse(model.canReview, "a report cannot be reviewed while attachments are changing")
            assertFalse(model.addScreenshotProviders([provider]), "a reentrant drop cannot bypass the attachment count")
            await feedbackWaitForAttachments(model)
            assertNil(model.errorMessage, "a valid byte-only drop finishes without error")
            assertEqual(model.attachments.count, 1, "one drop adds one attachment")
            assertTrue(model.step == .compose, "attaching does not submit or advance the report")
            if let image = model.attachments.first {
                do { try image.validate() }
                catch { assertTrue(false, "normalized byte-only attachment should validate") }
                assertEqual(image.mimeType, "image/jpeg", "the shared normalizer produces bounded JPEG output")
                assertNil(image.data.range(of: Data(marker.utf8)), "source metadata does not survive the drop route")
                assertTrue(image.data.count <= FeedbackAttachment.maximumBytes, "dropped screenshot fits the mail limit")
            }
        }

        await runSuite("Finder file URLs and TIFF image providers share the safe attachment path") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcripted-feedback-drop-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("synthetic-private-file.png")
                try png.write(to: file)
                let fileProvider = NSItemProvider(object: file as NSURL)
                let tiff = try feedbackProviderImage(type: UTType.tiff.identifier, author: marker)
                assertTrue(model.addScreenshotProviders([fileProvider, feedbackDataProvider(tiff, type: UTType.tiff.identifier)]), "Finder and image-app representations can be added together")
                await feedbackWaitForAttachments(model)
                assertNil(model.errorMessage, "valid URL and TIFF representations finish without error")
                assertEqual(model.attachments.count, 3, "the existing image and two new images are retained")
                assertTrue(model.attachments.allSatisfy { $0.mimeType == "image/jpeg" }, "all input routes normalize to the same output format")
                assertTrue(model.attachments.allSatisfy { !$0.filename.contains("private") }, "source filenames are not used in reports")
                assertFalse(model.addScreenshotProviders([feedbackDataProvider(png, type: UTType.png.identifier)]), "a fourth image is rejected before loading")
                assertFalse(model.isLoadingAttachments, "a rejected over-capacity drop does not start asynchronous work")
                assertEqual(model.attachments.count, 3, "rejected drops preserve selected images")
            } catch { assertTrue(false, "synthetic file-provider fixture failed: \(error)") }
        }

        await runSuite("JPEG and HEIC photo providers use the same bounded screenshot normalization") {
            for type in [UTType.jpeg.identifier, UTType.heic.identifier] {
                let photoModel = FeedbackComposerModel(appVersion: "synthetic", diagnostics: diagnostics)
                do {
                    let photo = try feedbackProviderImage(type: type, author: marker)
                    assertTrue(photoModel.addScreenshotProviders([feedbackDataProvider(photo, type: type)]), "a supported photo representation is accepted")
                    await feedbackWaitForAttachments(photoModel)
                    assertNil(photoModel.errorMessage, "the supported photo decodes and normalizes")
                    assertEqual(photoModel.attachments.count, 1, "one photo becomes one screenshot attachment")
                    assertEqual(photoModel.attachments.first?.mimeType, "image/jpeg", "the outgoing photo format stays compatible with support mail")
                    assertTrue((photoModel.attachments.first?.data.count ?? Int.max) <= FeedbackAttachment.maximumBytes, "normalized photo bytes remain bounded")
                } catch { assertTrue(false, "synthetic photo fixture failed: \(error)") }
            }
        }

        await runSuite("Invalid dropped data never fetches a network URL or discards existing attachments") {
            let keeper = model.attachments.first!
            for image in model.attachments.dropFirst() { model.removeScreenshot(image.id) }
            let remote = feedbackDataProvider(URL(string: "https://example.invalid/private.png")!.dataRepresentation, type: UTType.fileURL.identifier)
            assertTrue(model.addScreenshotProviders([remote]), "a declared file URL is resolved before validating its scheme")
            await feedbackWaitForAttachments(model)
            assertNotNil(model.errorMessage, "a non-file URL is refused locally")
            assertEqual(model.attachments, [keeper], "a refused URL leaves the existing screenshot untouched")

            let text = feedbackDataProvider(Data("not an image".utf8), type: UTType.plainText.identifier)
            assertTrue(model.addScreenshotProviders([feedbackDataProvider(png, type: UTType.png.identifier), text]), "batch validation reports an unsupported item")
            await feedbackWaitForAttachments(model)
            assertNotNil(model.errorMessage, "an unsupported representation has a visible explanation")
            assertEqual(model.attachments, [keeper], "a failed mixed batch is atomic and preserves the prior selection")

            let oversized = feedbackDataProvider(Data(repeating: 0, count: FeedbackAttachment.inputLimit + 1), type: UTType.png.identifier)
            assertTrue(model.addScreenshotProviders([oversized]), "size is checked when provider bytes arrive")
            await feedbackWaitForAttachments(model)
            assertNotNil(model.errorMessage, "oversized provider data is refused before decoding")
            assertEqual(model.attachments, [keeper], "oversized data does not replace existing attachments")
            assertEqual(model.message, "A screenshot is easier than describing the layout.", "failed drops never erase the written message")
            assertFalse(model.addScreenshotProviders([]), "an empty drop does not start work")
        }
    } catch { assertTrue(false, "synthetic screenshot provider setup failed: \(error)") }
}

@MainActor
private func feedbackWaitForAttachments(_ model: FeedbackComposerModel) async {
    if model.isLoadingAttachments {
        for await loading in model.$isLoadingAttachments.values {
            if !loading { break }
        }
    }
}

private func feedbackDataProvider(_ data: Data, type: String) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
        completion(data, nil)
        return nil
    }
    return provider
}

private func feedbackProviderImage(type: String, author: String) throws -> Data {
    let width = 32
    let height = 32
    let provider = CGDataProvider(data: Data(repeating: 120, count: width * height * 4) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else {
        throw FeedbackSubmissionError.unsupportedImage
    }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: author]] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw FeedbackSubmissionError.unsupportedImage }
    return output as Data
}

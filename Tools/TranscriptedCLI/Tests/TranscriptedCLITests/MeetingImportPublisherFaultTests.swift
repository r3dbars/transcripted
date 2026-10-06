import Darwin
import Foundation
import XCTest
@testable import transcripted_cli

final class MeetingImportPublisherFaultTests: XCTestCase {
    func testLostPublicationAcknowledgementPreservesCompleteTranscriptAudioAndRecoveryCopy() throws {
        for code in [EIO, ETIMEDOUT, EEXIST] {
            for plainFilename in [false, true] {
                try withFixture(retainAudio: true) { fixture in
                    var attempts = 0
                    var staging: URL?
                    var destination: URL?
                    let error = publicationError {
                        try fixture.publish(plainFilename: plainFilename) { fromFD, from, toFD, to in
                            attempts += 1
                            staging = fixture.output.appendingPathComponent(from)
                            destination = fixture.output.appendingPathComponent(to)
                            XCTAssertEqual(Darwin.linkat(fromFD, from, toFD, to, 0), 0)
                            errno = code
                            return -1
                        }
                    }

                    XCTAssertEqual(error?.code, Int(code))
                    XCTAssertEqual(error?.domain, "MeetingImportPublisher.UncertainPublication")
                    XCTAssertEqual(attempts, 1, "An uncertain result must not retry another name")
                    let final = try XCTUnwrap(destination)
                    XCTAssertEqual(try Data(contentsOf: final), fixture.markdown)
                    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(staging)), fixture.markdown)
                    XCTAssertEqual(
                        try children(fixture.output).filter { $0.pathExtension == "md" }
                            .map { $0.resolvingSymlinksInPath().path },
                        [final.resolvingSymlinksInPath().path]
                    )
                    try fixture.assertRetainedAudio(for: final)
                    try fixture.assertSourceUnchanged()
                }
            }
        }
    }

    func testUnknownPublicationOutcomeKeepsRecoverableFilesEvenWhenNoLinkWasMade() throws {
        for code in [EIO, ETIMEDOUT, ECONNRESET, EBUSY, EEXIST] {
            try withFixture(retainAudio: true) { fixture in
                var attempts = 0
                var staging: URL?
                var destination: URL?
                let error = publicationError {
                    try fixture.publish { _, from, _, to in
                        attempts += 1
                        staging = fixture.output.appendingPathComponent(from)
                        destination = fixture.output.appendingPathComponent(to)
                        errno = code
                        return -1
                    }
                }

                XCTAssertEqual(error?.code, Int(code))
                XCTAssertEqual(error?.domain, "MeetingImportPublisher.UncertainPublication")
                XCTAssertEqual(attempts, 1)
                let final = try XCTUnwrap(destination)
                XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(staging)), fixture.markdown)
                XCTAssertTrue(try children(fixture.output).filter { $0.pathExtension == "md" }.isEmpty)
                try fixture.assertRetainedAudio(for: final)
                try fixture.assertSourceUnchanged()
            }
        }
    }

    func testUncertainPublicationWithoutAudioPreservesRecoveryCopyAndAnyPublishedTranscript() throws {
        for didPublish in [false, true] {
            try withFixture(retainAudio: false) { fixture in
                var attempts = 0
                var staging: URL?
                var destination: URL?
                let error = publicationError {
                    try fixture.publish { fromFD, from, toFD, to in
                        attempts += 1
                        staging = fixture.output.appendingPathComponent(from)
                        destination = fixture.output.appendingPathComponent(to)
                        if didPublish {
                            XCTAssertEqual(Darwin.linkat(fromFD, from, toFD, to, 0), 0)
                        }
                        errno = EIO
                        return -1
                    }
                }

                XCTAssertEqual(error?.code, Int(EIO))
                XCTAssertEqual(error?.domain, "MeetingImportPublisher.UncertainPublication")
                XCTAssertEqual(attempts, 1)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(staging)), fixture.markdown)
                let final = try XCTUnwrap(destination)
                if didPublish {
                    XCTAssertEqual(try Data(contentsOf: final), fixture.markdown)
                } else {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("audio").path))
                XCTAssertEqual(try children(fixture.output).count, didPublish ? 2 : 1)
            }
        }
    }

    func testUnsupportedPublicationCleansOwnedArtifactsAndExplainsSafeLocalExport() throws {
        for code in Set([ENOTSUP, EOPNOTSUPP]) {
            for retainAudio in [false, true] {
                try withFixture(retainAudio: retainAudio) { fixture in
                    var attempts = 0
                    let error = publicationError {
                        try fixture.publish { _, _, _, _ in
                            attempts += 1
                            errno = code
                            return -1
                        }
                    }

                    XCTAssertEqual(error?.domain, NSPOSIXErrorDomain)
                    XCTAssertEqual(error?.code, Int(code))
                    XCTAssertEqual(attempts, 1, "A different filename cannot add filesystem support")
                    let message = try XCTUnwrap(error).localizedDescription.lowercased()
                    XCTAssertTrue(message.contains("--output-dir"))
                    XCTAssertTrue(message.contains("--no-retain-audio"))
                    XCTAssertTrue(message.contains("copy"))
                    XCTAssertTrue(message.contains("without replacing"))
                    XCTAssertEqual(try children(fixture.output).map(\.lastPathComponent), retainAudio ? ["audio"] : [])
                    if retainAudio {
                        XCTAssertTrue(try children(fixture.output.appendingPathComponent("audio")).isEmpty)
                    }
                    try fixture.assertSourceUnchanged()
                }
            }
        }
    }

    func testDefiniteFinalCollisionCleansOwnedAudioAndLeavesExistingTranscriptUntouched() throws {
        try withFixture(retainAudio: true) { fixture in
            var attempts = 0
            var destination: URL?
            let existing = Data("# Existing capture\n".utf8)
            let error = publicationError {
                try fixture.publish(plainFilename: false) { fromFD, from, toFD, to in
                    attempts += 1
                    let final = fixture.output.appendingPathComponent(to)
                    destination = final
                    do {
                        try existing.write(to: final, options: .withoutOverwriting)
                    } catch {
                        XCTFail("Could not create the synthetic collision fixture")
                        errno = EIO
                        return -1
                    }
                    return Darwin.linkat(fromFD, from, toFD, to, 0)
                }
            }

            XCTAssertEqual(error?.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(error?.code, Int(EEXIST))
            XCTAssertEqual(attempts, 1)
            let final = try XCTUnwrap(destination)
            XCTAssertEqual(try Data(contentsOf: final), existing)
            XCTAssertEqual(Set(try children(fixture.output).map(\.lastPathComponent)), ["audio", final.lastPathComponent])
            XCTAssertTrue(try children(fixture.output.appendingPathComponent("audio")).isEmpty)
            try fixture.assertSourceUnchanged()
        }
    }

    func testDefinitePlainNameCollisionRetriesOnceAndCleansOnlyTheAbandonedArchive() throws {
        try withFixture(retainAudio: true) { fixture in
            var attempts = 0
            var original: URL?
            let existing = Data("# Existing capture\n".utf8)
            let receipt = try fixture.publish { fromFD, from, toFD, to in
                attempts += 1
                if attempts == 1 {
                    let final = fixture.output.appendingPathComponent(to)
                    original = final
                    do {
                        try existing.write(to: final, options: .withoutOverwriting)
                    } catch {
                        XCTFail("Could not create the synthetic collision fixture")
                        errno = EIO
                        return -1
                    }
                }
                return Darwin.linkat(fromFD, from, toFD, to, 0)
            }

            XCTAssertEqual(attempts, 2)
            let first = try XCTUnwrap(original)
            let final = URL(fileURLWithPath: receipt.transcriptPath)
            XCTAssertNotEqual(final, first)
            XCTAssertEqual(try Data(contentsOf: first), existing)
            XCTAssertEqual(try Data(contentsOf: final), fixture.markdown)
            XCTAssertEqual(Set(try children(fixture.output).map(\.lastPathComponent)), ["audio", first.lastPathComponent, final.lastPathComponent])
            try fixture.assertRetainedAudio(for: final)
            try fixture.assertSourceUnchanged()
        }
    }

    private func publicationError(_ action: () throws -> MeetingImportReceipt) -> NSError? {
        do {
            _ = try action()
            XCTFail("Publication with a failed acknowledgement must not report success")
            return nil
        } catch {
            return error as NSError
        }
    }

    private func withFixture(retainAudio: Bool, _ body: (PublisherFaultFixture) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let root = temporary.appendingPathComponent("MeetingImportPublisherFaultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            if root.deletingLastPathComponent() == temporary,
               root.lastPathComponent.hasPrefix("MeetingImportPublisherFaultTests-") {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let fixture = PublisherFaultFixture(root: root, retainAudio: retainAudio)
        if let source = fixture.source {
            try fixture.sourceBytes.write(to: source, options: .withoutOverwriting)
        }
        try body(fixture)
    }

    private func children(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
}

private struct PublisherFaultFixture {
    let root: URL
    let retainAudio: Bool
    let sourceBytes = Data((0..<4096).map { UInt8($0 % 251) })
    let markdown = Data("# Synthetic publication\n\nComplete synthetic transcript.\n".utf8)

    var output: URL { root.appendingPathComponent("meetings", isDirectory: true).resolvingSymlinksInPath() }
    var source: URL? { retainAudio ? root.appendingPathComponent("synthetic-normalized.wav") : nil }

    func publish(
        plainFilename: Bool = true,
        link: (Int32, String, Int32, String) -> Int32
    ) throws -> MeetingImportReceipt {
        try MeetingImportPublisher.publish(
            markdown: String(decoding: markdown, as: UTF8.self), normalizedAudioURL: source,
            outputDirectory: output, title: "Synthetic", captureID: UUID(),
            date: Date(timeIntervalSince1970: 1_700_000_000), plainFilename: plainFilename,
            beforeCommit: {}, link: link
        )
    }

    func assertSourceUnchanged() throws {
        if let source {
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        }
    }

    func assertRetainedAudio(for transcript: URL) throws {
        let archiveName = transcript.deletingPathExtension().lastPathComponent + "_audio"
        let audio = output.appendingPathComponent("audio", isDirectory: true)
        let archive = audio.appendingPathComponent(archiveName, isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audio.path), [archiveName])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: archive.path), ["system_audio.wav"])
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("system_audio.wav")), sourceBytes)
    }
}

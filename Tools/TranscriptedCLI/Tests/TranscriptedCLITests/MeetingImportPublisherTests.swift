import Foundation
import XCTest
@testable import transcripted_cli

final class MeetingImportPublisherTests: XCTestCase {
    private let captureID = UUID(uuidString: "3D7EDB0D-436A-449E-8B11-BA21416AF384")!
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testPublishesMarkdownWithoutRetainingAudio() throws {
        try withRoot { root in
            let receipt = try publish(in: root)
            XCTAssertEqual(try String(contentsOfFile: receipt.transcriptPath), "# Synthetic meeting\n")
            XCTAssertNil(receipt.audioPath)
            XCTAssertEqual(receipt.captureID, captureID.uuidString)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("audio").path))
            XCTAssertEqual(try children(root).count, 1)
            XCTAssertEqual(try permissions(URL(fileURLWithPath: receipt.transcriptPath)), 0o600)
            let decoded = try JSONDecoder().decode(MeetingImportReceipt.self, from: JSONEncoder().encode(receipt))
            XCTAssertEqual(decoded.transcriptPath, receipt.transcriptPath)
            XCTAssertNil(decoded.audioPath)
        }
    }

    func testRetainsIndependentAudioCopyAndPreservesSource() throws {
        try withRoot { root in
            let source = try makeSource(in: root)
            let original = try Data(contentsOf: source)
            let before = try FileManager.default.attributesOfItem(atPath: source.path)
            let receipt = try publish(in: root.appendingPathComponent("meetings"), audio: source)
            let retained = try XCTUnwrap(receipt.audioPath).asFileURL
            XCTAssertEqual(retained.lastPathComponent, "system_audio.wav")
            XCTAssertEqual(retained.deletingLastPathComponent().lastPathComponent,
                           receipt.transcriptPath.asFileURL.deletingPathExtension().lastPathComponent + "_audio")
            XCTAssertEqual(try Data(contentsOf: retained), try Data(contentsOf: source))
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try permissions(retained), 0o600)
            let after = try FileManager.default.attributesOfItem(atPath: source.path)
            XCTAssertEqual(after[.posixPermissions] as? NSNumber, before[.posixPermissions] as? NSNumber)
            XCTAssertEqual(after[.modificationDate] as? Date, before[.modificationDate] as? Date)
            XCTAssertEqual(after[.size] as? NSNumber, before[.size] as? NSNumber)
            XCTAssertNotEqual(after[.systemFileNumber] as? NSNumber,
                              try FileManager.default.attributesOfItem(atPath: retained.path)[.systemFileNumber] as? NSNumber)
        }
    }

    func testDuplicateIdentityDoesNotReplaceExistingTranscript() throws {
        try withRoot { root in
            let receipt = try publish(in: root)
            XCTAssertThrowsError(try publish(in: root, markdown: "replacement"))
            XCTAssertEqual(try String(contentsOfFile: receipt.transcriptPath), "# Synthetic meeting\n")
            XCTAssertEqual(try children(root).count, 1, "Failed publication must remove its staging file")
        }
    }

    func testConcurrentPublicationsWithoutAudioHaveOneWinner() throws {
        try assertConcurrentPublications(retainAudio: false)
    }

    func testConcurrentPublicationsWithAudioHaveOneWinner() throws {
        try assertConcurrentPublications(retainAudio: true)
    }

    func testDifferentCaptureIdentitiesWithSameTitleProduceDifferentFiles() throws {
        try withRoot { root in
            let first = try publish(in: root)
            let second = try MeetingImportPublisher.publish(
                markdown: "# Second synthetic meeting\n", normalizedAudioURL: nil,
                outputDirectory: root, title: "Synthetic", captureID: UUID(), date: date
            )
            XCTAssertNotEqual(first.transcriptPath, second.transcriptPath)
            XCTAssertEqual(try children(root).count, 2)
        }
    }

    func testUnicodeTitleIsBoundedAndCannotCreateChildPaths() throws {
        try withRoot { root in
            let receipt = try publish(in: root, title: "Café 東京 👩🏽‍💻 / .. \\ :\n" + String(repeating: "é", count: 300))
            let file = receipt.transcriptPath.asFileURL
            XCTAssertEqual(file.deletingLastPathComponent().path, root.resolvingSymlinksInPath().path)
            XCTAssertTrue(file.lastPathComponent.contains("Café 東京 👩🏽‍💻"))
            XCTAssertTrue(file.lastPathComponent.contains(captureID.uuidString.lowercased()))
            XCTAssertFalse(file.lastPathComponent.contains("/"))
            XCTAssertFalse(file.lastPathComponent.contains("\\"))
            XCTAssertFalse(file.lastPathComponent.contains(":"))
            XCTAssertLessThan(file.lastPathComponent.decomposedStringWithCanonicalMapping.utf8.count, 255)
            XCTAssertEqual(try children(root).count, 1)
        }
    }

    func testSymlinkedLibraryRootReturnsCanonicalPaths() throws {
        try withRoot { root in
            let real = root.appendingPathComponent("real")
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
            let receipt = try publish(in: alias)
            XCTAssertEqual(receipt.transcriptPath.asFileURL.deletingLastPathComponent().path, real.resolvingSymlinksInPath().path)
        }
    }

    func testRejectsSymlinkedAudioDirectoryWithoutTouchingTarget() throws {
        try withRoot { root in
            let source = try makeSource(in: root)
            let output = root.appendingPathComponent("meetings")
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let sentinel = outside.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("audio"), withDestinationURL: outside)
            XCTAssertThrowsError(try publish(in: output, audio: source))
            XCTAssertEqual(try String(contentsOf: sentinel), "keep")
            XCTAssertEqual(try children(outside).count, 1)
            XCTAssertEqual(try children(output).count, 1)
        }
    }

    func testCommitCollisionRemovesOnlyItsUncommittedAudio() throws {
        try withRoot { root in
            let source = try makeSource(in: root)
            let original = try Data(contentsOf: source)
            let output = root.appendingPathComponent("meetings")
            let receipt = try publish(in: output)
            XCTAssertThrowsError(try publish(in: output, audio: source, markdown: "replacement"))
            XCTAssertEqual(try String(contentsOfFile: receipt.transcriptPath), "# Synthetic meeting\n")
            XCTAssertEqual(try children(output.appendingPathComponent("audio")).count, 0)
            XCTAssertFalse(try children(output).contains { $0.lastPathComponent.hasPrefix(".") })
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testCopyFailureLeavesNoTranscriptOrOwnedArchive() throws {
        try withRoot { root in
            let missing = root.appendingPathComponent("missing.wav")
            XCTAssertThrowsError(try publish(in: root, audio: missing))
            XCTAssertEqual(try children(root).map(\.lastPathComponent), ["audio"])
            XCTAssertTrue(try children(root.appendingPathComponent("audio")).isEmpty)
        }
    }

    func testExistingOutputAndAudioDirectoryPermissionsAreUnchanged() throws {
        try withRoot { root in
            let source = try makeSource(in: root)
            let output = root.appendingPathComponent("meetings")
            let audio = output.appendingPathComponent("audio")
            try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: audio.path)
            _ = try publish(in: output, audio: source)
            XCTAssertEqual(try permissions(output), 0o755)
            XCTAssertEqual(try permissions(audio), 0o750)
        }
    }

    func testExistingFinalSymlinkIsNeverFollowedOrReplaced() throws {
        try withRoot { root in
            let receipt = try publish(in: root)
            let destination = receipt.transcriptPath.asFileURL
            let sentinel = root.appendingPathComponent("sentinel.txt")
            try Data("keep".utf8).write(to: sentinel)
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: sentinel)
            XCTAssertThrowsError(try publish(in: root))
            XCTAssertEqual(try String(contentsOf: sentinel), "keep")
            XCTAssertTrue(try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        }
    }

    func testCancellationBeforePublicationDoesNotCreateDestination() async throws {
        try await withAsyncRoot { root in
            let output = root.appendingPathComponent("meetings")
            let id = captureID
            let job = Task.detached { () -> Bool in
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    _ = try MeetingImportPublisher.publish(
                        markdown: "# Cancelled synthetic meeting\n", normalizedAudioURL: nil,
                        outputDirectory: output, title: "Cancelled", captureID: id
                    )
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
            let cancelled = await job.value
            XCTAssertTrue(cancelled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testAudioDirectorySwapBeforeCommitDoesNotFollowReplacementSymlink() throws {
        try withRoot { root in
            let source = try makeSource(in: root)
            let output = root.appendingPathComponent("meetings")
            let outside = root.appendingPathComponent("outside")
            let moved = root.appendingPathComponent("moved-audio")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let sentinel = outside.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: sentinel)
            XCTAssertThrowsError(try MeetingImportPublisher.publish(
                markdown: "# Synthetic meeting\n", normalizedAudioURL: source,
                outputDirectory: output, title: "Synthetic", captureID: captureID, date: date,
                beforeCommit: {
                    let audio = output.appendingPathComponent("audio")
                    try FileManager.default.moveItem(at: audio, to: moved)
                    try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: outside)
                }
            ))
            XCTAssertEqual(try String(contentsOf: sentinel), "keep")
            XCTAssertEqual(try children(outside).count, 1)
            XCTAssertTrue(try children(moved).isEmpty, "Cleanup follows the owned directory descriptor")
            XCTAssertEqual(try children(output).map(\.lastPathComponent), ["audio"])
        }
    }

    func testCancellationAtCommitRemovesOwnAudioAndStagingAndPreservesSource() async throws {
        try await withAsyncRoot { root in
            let source = try makeSource(in: root)
            let original = try Data(contentsOf: source)
            let output = root.appendingPathComponent("meetings")
            let existing = try publish(in: output, title: "Keep this meeting")
            let id = captureID
            let recorded = date
            let job = Task.detached { () -> Bool in
                do {
                    _ = try MeetingImportPublisher.publish(
                        markdown: "# Cancelled synthetic meeting\n", normalizedAudioURL: source,
                        outputDirectory: output, title: "Cancelled", captureID: id, date: recorded,
                        beforeCommit: { withUnsafeCurrentTask { $0?.cancel() } }
                    )
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
            let cancelled = await job.value
            XCTAssertTrue(cancelled)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try String(contentsOfFile: existing.transcriptPath), "# Synthetic meeting\n")
            XCTAssertEqual(try children(output).filter { $0.pathExtension == "md" }.count, 1)
            XCTAssertTrue(try children(output.appendingPathComponent("audio")).isEmpty)
            XCTAssertFalse(try children(output).contains { $0.lastPathComponent.hasPrefix(".") })
        }
    }

    private func assertConcurrentPublications(retainAudio: Bool) throws {
        try withRoot { root in
            let source = retainAudio ? try makeSource(in: root) : nil
            let output = root.appendingPathComponent("meetings")
            let results = PublisherResults()
            let id = captureID
            let recorded = date
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                do {
                    let receipt = try MeetingImportPublisher.publish(
                        markdown: "# Concurrent synthetic meeting\n", normalizedAudioURL: source,
                        outputDirectory: output, title: "Concurrent", captureID: id, date: recorded
                    )
                    results.record(receipt)
                } catch {
                    results.recordFailure()
                }
            }
            XCTAssertEqual(results.receipts.count, 1)
            XCTAssertEqual(results.failures, 7)
            let winner = try XCTUnwrap(results.receipts.first)
            XCTAssertEqual(try String(contentsOfFile: winner.transcriptPath), "# Concurrent synthetic meeting\n")
            XCTAssertFalse(try children(output).contains { $0.lastPathComponent.hasPrefix(".") })
            if let source {
                XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(winner.audioPath).asFileURL), try Data(contentsOf: source))
                XCTAssertEqual(try children(output.appendingPathComponent("audio")).count, 1)
            }
        }
    }

    private func publish(
        in directory: URL, audio: URL? = nil, title: String = "Synthetic", markdown: String = "# Synthetic meeting\n"
    ) throws -> MeetingImportReceipt {
        try MeetingImportPublisher.publish(
            markdown: markdown, normalizedAudioURL: audio, outputDirectory: directory,
            title: title, captureID: captureID, date: date
        )
    }

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingImportPublisherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func withAsyncRoot(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingImportPublisherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private func makeSource(in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("synthetic-normalized.wav")
        try Data((0..<4096).map { UInt8($0 % 256) }).write(to: source)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644, .modificationDate: date], ofItemAtPath: source.path
        )
        return source
    }

    private func children(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }
}

private extension String {
    var asFileURL: URL { URL(fileURLWithPath: self) }
}

private final class PublisherResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var receipts: [MeetingImportReceipt] = []
    private(set) var failures = 0

    func record(_ receipt: MeetingImportReceipt) {
        lock.lock()
        defer { lock.unlock() }
        receipts.append(receipt)
    }

    func recordFailure() {
        lock.lock()
        defer { lock.unlock() }
        failures += 1
    }
}

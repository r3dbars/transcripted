#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import TranscriptedCaptureKit
import TranscriptedCore
import XCTest
@testable import transcripted_cli

/// Opt-in, real-model proof of the built executable, not a mocked command call.
/// Supply only synthetic/approved file audio. This test never records or plays
/// audio and never opens the user's real speaker database or capture library.
/// Self-recognition from the same fixture proves wiring, not real-world speaker
/// identification accuracy across different recordings or microphones.
final class ImportAudioExecutableE2ETests: XCTestCase {
    func testRealExecutableRejectsMissingCorruptAndShortInputs() async throws {
        let configuration = try Configuration.fromEnvironment()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.wav")
        let corrupt = root.appendingPathComponent("corrupt.wav")
        try Data("Not an audio file".utf8).write(to: corrupt)
        let short = root.appendingPathComponent("short.wav")
        try writeSilentWAV(to: short, duration: 0.5)
        let proofs = try [corrupt, short].map { ($0, try FileProof($0)) }
        for (input, expectedError) in [(missing, "existing regular audio/video file"), (corrupt, ""), (short, "at least 2 seconds")] {
            let output = root.appendingPathComponent("output-\(UUID().uuidString)")
            let result = try await runExecutable(
                configuration.binary,
                arguments: importArguments(configuration, input: input, output: output, extra: ["--no-speaker-identification"]),
                root: root, timeout: 30, expectSuccess: false
            )
            try assertFailedWithoutCapture(result, output: output)
            if !expectedError.isEmpty { XCTAssertTrue(result.stderr.contains(expectedError), result.stderr) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        for (url, proof) in proofs { XCTAssertEqual(try FileProof(url), proof) }
    }

    func testRealExecutableRejectsMissingModelsDiarizerAndExplicitSpeakerDatabase() async throws {
        let configuration = try Configuration.fromEnvironment()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try copyFixture(configuration, into: root)
        let before = try FileProof(input)
        let missing = root.appendingPathComponent("missing-dependency")
        let cases = [
            (models: missing, diarizer: configuration.diarizationModels, extra: ["--no-speaker-identification"], error: "Incomplete Parakeet v3 models"),
            (models: configuration.models, diarizer: missing, extra: ["--no-speaker-identification"], error: "Incomplete diarization models"),
            (models: configuration.models, diarizer: configuration.diarizationModels, extra: ["--speaker-db", missing.path], error: "Speaker database not found"),
        ]
        for testCase in cases {
            let output = root.appendingPathComponent("output-\(UUID().uuidString)")
            let result = try await runExecutable(
                configuration.binary,
                arguments: importArguments(configuration, input: input, output: output,
                                           models: testCase.models, diarizer: testCase.diarizer, extra: testCase.extra),
                root: root, timeout: 180, expectSuccess: false
            )
            try assertFailedWithoutCapture(result, output: output)
            XCTAssertTrue(result.stderr.contains(testCase.error), result.stderr)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(try FileProof(input), before)
    }

    func testRealExecutableRejectsSilenceThenSuccessfullyRetriesInSameOutputDirectory() async throws {
        let configuration = try Configuration.fromEnvironment()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let silent = root.appendingPathComponent("silence.wav")
        try writeSilentWAV(to: silent, duration: 5)
        let silentBefore = try FileProof(silent)
        let output = root.appendingPathComponent("retry-output")
        let failed = try await runExecutable(
            configuration.binary,
            arguments: importArguments(configuration, input: silent, output: output, extra: ["--no-speaker-identification"]),
            root: root, timeout: 600, expectSuccess: false
        )
        try assertFailedWithoutCapture(failed, output: output)
        XCTAssertTrue(failed.stderr.lowercased().contains("no speech detected"), failed.stderr)
        XCTAssertEqual(try FileProof(silent), silentBefore)

        let input = try copyFixture(configuration, into: root)
        let before = try FileProof(input)
        let success = try await runImport(configuration: configuration, input: input, outputDirectory: output,
                                          extraArguments: ["--no-retain-audio", "--no-speaker-identification"], root: root)
        _ = try assertCapture(String(contentsOfFile: success.transcriptPath, encoding: .utf8), receipt: success, configuration: configuration)
        XCTAssertEqual(try FileProof(input), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).filter { $0.hasSuffix(".md") }.count, 1)
    }

    func testRealExecutableRejectsFileOutputAndAudioDirectorySymlinkWithoutOverwriting() async throws {
        let configuration = try Configuration.fromEnvironment()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try copyFixture(configuration, into: root)
        let inputBefore = try FileProof(input)
        let occupied = root.appendingPathComponent("occupied-output")
        try Data("Unrelated output sentinel".utf8).write(to: occupied)
        let occupiedBefore = try FileProof(occupied)
        let fileFailure = try await runExecutable(
            configuration.binary,
            arguments: importArguments(configuration, input: input, output: occupied, extra: ["--no-speaker-identification"]),
            root: root, timeout: 600, expectSuccess: false
        )
        try assertFailedWithoutCapture(fileFailure, output: occupied)
        XCTAssertEqual(try FileProof(occupied), occupiedBefore)

        let output = root.appendingPathComponent("symlink-output", isDirectory: true)
        let outside = root.appendingPathComponent("unrelated-outside", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("Unrelated outside sentinel".utf8).write(to: sentinel)
        let sentinelBefore = try FileProof(sentinel)
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("audio"), withDestinationURL: outside)
        let linkFailure = try await runExecutable(
            configuration.binary,
            arguments: importArguments(configuration, input: input, output: output, extra: ["--no-speaker-identification"]),
            root: root, timeout: 600, expectSuccess: false
        )
        try assertFailedWithoutCapture(linkFailure, output: output)
        XCTAssertTrue(linkFailure.stderr.contains("symlinks below the library root are not allowed"), linkFailure.stderr)
        XCTAssertEqual(try FileProof(sentinel), sentinelBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["keep.txt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["audio"])
        XCTAssertEqual(try FileProof(input), inputBefore)
    }

    func testRealExecutableSIGINTDuringModelLoadCleansScratchAndReturns130() async throws {
        try await assertCancellation(signal: SIGINT)
    }

    func testRealExecutableSIGTERMDuringModelLoadCleansScratchAndReturns143() async throws {
        try await assertCancellation(signal: SIGTERM)
    }

    func testRealExecutableRetainsAudioRecognizesSnapshotAndSupportsMarkdownOnly() async throws {
        let configuration = try Configuration.fromEnvironment()
        setenv("TRANSCRIPTED_DISABLE_FILE_LOGGER", "1", 1)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ImportAudioExecutableE2E-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }

        let providedAudioBefore = try FileProof(configuration.audio)
        let input = root.appendingPathComponent("äänet fixture.\(configuration.audio.pathExtension)")
        try fm.copyItem(at: configuration.audio, to: input)
        let inputBefore = try FileProof(input)
        let normalized = root.appendingPathComponent("seed-normalized.wav")
        try await MeetingImportWorkflow.normalize(input, to: normalized)
        let decoded = try await TranscribeMediaLoader.loadSamples(from: normalized)
        guard decoded.durationSeconds >= 10 else {
            throw Failure("E2E fixture must contain at least ten seconds of synthetic speech.")
        }

        // The only writable speaker store in this test is newly created here.
        // Keep it open during child execution so recognition must see WAL rows.
        let speakerDBURL = root.appendingPathComponent("synthetic-speakers.sqlite")
        let speakerStore = SpeakerDatabase(path: speakerDBURL.path)
        let knownName = "Fixture Voice Alpha"
        let knownID = try await seedKnownSpeaker(
            samples: decoded.samples, models: configuration.diarizationModels,
            store: speakerStore, name: knownName
        )
        let profileBefore = try XCTUnwrap(speakerStore.getSpeaker(id: knownID))
        XCTAssertTrue(SpeakerNamingPolicy.isAutoRecognizable(profile: profileBefore, recentOutcomes: []))
        let databaseBefore = try DatabaseProof(speakerDBURL)

        let retainedDirectory = root.appendingPathComponent("retained äänet", isDirectory: true)
        let retained = try await runImport(
            configuration: configuration, input: input, outputDirectory: retainedDirectory,
            extraArguments: ["--speaker-db", speakerDBURL.path, "--title", "CLI ää fixture"], root: root
        )
        let retainedMarkdown = try String(contentsOfFile: retained.transcriptPath, encoding: .utf8)
        let retainedCapture = try assertCapture(retainedMarkdown, receipt: retained, configuration: configuration)
        let namedSpeakers = retainedCapture.speakers.filter { $0.name == knownName }
        XCTAssertFalse(namedSpeakers.isEmpty, "The real pipeline must recognize the seeded, eligible fixture voice.")
        XCTAssertTrue(namedSpeakers.allSatisfy { $0.persistentSpeakerId == knownID.uuidString })
        XCTAssertTrue(retainedCapture.speakers.allSatisfy {
            $0.persistentSpeakerId == nil || $0.persistentSpeakerId == knownID.uuidString
        }, "Temporary snapshot-only profile IDs must not escape into saved captures.")
        let retainedAudioPath = try XCTUnwrap(retained.audioPath)
        XCTAssertEqual(URL(fileURLWithPath: retainedAudioPath).lastPathComponent, "system_audio.wav")
        let retainedAudio = try AVAudioFile(forReading: URL(fileURLWithPath: retainedAudioPath))
        XCTAssertEqual(Double(retainedAudio.length) / retainedAudio.fileFormat.sampleRate, decoded.durationSeconds, accuracy: 0.02)
        XCTAssertEqual(retainedAudio.fileFormat.channelCount, 1)
        XCTAssertEqual(retainedAudio.fileFormat.sampleRate, 16_000)

        // Prove the separate CLI read command can consume the committed artifact.
        let readback = try await runExecutable(
            configuration.binary,
            arguments: ["read-meeting", URL(fileURLWithPath: retained.transcriptPath).lastPathComponent,
                        "--meetings-dir", retainedDirectory.path, "--json"],
            root: root, timeout: 30
        )
        let document = try JSONDecoder().decode(CLIReadMarkdownDocument.self, from: readback.stdout)
        XCTAssertEqual(document.markdown, retainedMarkdown)
        XCTAssertEqual(document.utterances?.count, retainedCapture.utterances.count)
        XCTAssertTrue(document.speakers?.contains(where: { $0.name == knownName }) == true)

        let markdownDirectory = root.appendingPathComponent("markdown-only", isDirectory: true)
        let markdownOnly = try await runImport(
            configuration: configuration, input: input, outputDirectory: markdownDirectory,
            extraArguments: ["--no-retain-audio", "--no-speaker-identification"], root: root
        )
        XCTAssertNil(markdownOnly.audioPath)
        let plainMarkdown = try String(contentsOfFile: markdownOnly.transcriptPath, encoding: .utf8)
        let plainCapture = try assertCapture(plainMarkdown, receipt: markdownOnly, configuration: configuration)
        XCTAssertTrue(plainCapture.speakers.allSatisfy { $0.persistentSpeakerId == nil })
        XCTAssertFalse(plainCapture.speakers.contains { $0.name == knownName })
        XCTAssertFalse(fm.fileExists(atPath: markdownDirectory.appendingPathComponent("audio").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: markdownDirectory.path),
                       [URL(fileURLWithPath: markdownOnly.transcriptPath).lastPathComponent])
        XCTAssertNotEqual(retained.captureID, markdownOnly.captureID)

        XCTAssertEqual(try FileProof(input), inputBefore, "Input bytes, modification time, size, and permissions must stay unchanged.")
        XCTAssertEqual(try FileProof(configuration.audio), providedAudioBefore)
        XCTAssertEqual(try DatabaseProof(speakerDBURL), databaseBefore, "Recognition must not modify the source SQLite database or WAL.")
        let profileAfter = try XCTUnwrap(speakerStore.getSpeaker(id: knownID))
        XCTAssertEqual(speakerStore.allSpeakers().count, 1)
        XCTAssertEqual(profileAfter.displayName, profileBefore.displayName)
        XCTAssertEqual(profileAfter.embedding, profileBefore.embedding)
        XCTAssertEqual(profileAfter.callCount, profileBefore.callCount)
        XCTAssertEqual(profileAfter.confirmedMeetingCount, profileBefore.confirmedMeetingCount)
        XCTAssertEqual(profileAfter.lastSeen, profileBefore.lastSeen)
    }

    private func seedKnownSpeaker(samples: [Float], models: URL, store: SpeakerDatabase, name: String) async throws -> UUID {
        let diarizer = await MainActor.run { DiarizationService(bundleProvider: { _ in models }) }
        await diarizer.initialize()
        guard await diarizer.isReady else {
            throw Failure("Fixture diarization models could not initialize; no download fallback is enabled.")
        }
        let rawSegments: [SpeakerSegment]
        do {
            rawSegments = try await diarizer.diarizeOffline(samples: samples)
            await diarizer.cleanup()
        } catch {
            await diarizer.cleanup()
            throw error
        }
        let segments = EmbeddingClusterer.postProcess(
            segments: rawSegments, existingProfiles: [], pairwiseMergeThreshold: nil,
            consolidationThreshold: SpeakerEmbeddingThresholds.weSpeaker.consolidation,
            thresholds: .weSpeaker
        )
        let eligible = segments.filter { $0.duration >= 1 && $0.qualityScore >= 0.3 && $0.embedding?.isEmpty == false }
        let grouped = Dictionary(grouping: eligible, by: \.speakerId)
        guard let dominant = grouped.values.max(by: {
            $0.reduce(0) { $0 + $1.duration } < $1.reduce(0) { $0 + $1.duration }
        }) else {
            throw Failure("The synthetic fixture produced no usable voice embeddings. Use a clear, speech-only fixture.")
        }
        let embedding = Transcription.computeMeanEmbedding(dominant.compactMap(\.embedding))
        let profile = store.addOrUpdateSpeaker(embedding: embedding)
        store.setDisplayName(id: profile.id, name: name)
        try store.recordUserConfirmations((0..<SpeakerNamingPolicy.requiredConfirmedMeetings).map { _ in
            SpeakerUserConfirmation(profileId: profile.id, transcriptId: UUID(), kind: .confirmed)
        })
        return profile.id
    }

    private func runImport(
        configuration: Configuration, input: URL, outputDirectory: URL,
        extraArguments: [String], root: URL
    ) async throws -> MeetingImportReceipt {
        let arguments = importArguments(configuration, input: input, output: outputDirectory, extra: extraArguments)
        let result = try await runExecutable(configuration.binary, arguments: arguments, root: root, timeout: 600)
        // Decode the entire stdout. Any model progress accidentally printed there
        // makes this fail rather than accepting an embedded JSON substring.
        let receipt = try JSONDecoder().decode(MeetingImportReceipt.self, from: result.stdout)
        XCTAssertNotNil(UUID(uuidString: receipt.captureID))
        XCTAssertEqual(URL(fileURLWithPath: receipt.transcriptPath).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath(),
                       outputDirectory.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.transcriptPath))
        return receipt
    }

    private func assertCapture(
        _ markdown: String, receipt: MeetingImportReceipt, configuration: Configuration
    ) throws -> ParsedMeetingCapture {
        let document = try XCTUnwrap(CaptureMarkdownParser.parseFrontmatter(from: markdown))
        XCTAssertEqual(document.values["capture_id"], receipt.captureID)
        XCTAssertEqual(document.values["capture_type"], "meeting")
        XCTAssertEqual(document.values["sources"], "system_audio")
        XCTAssertEqual(document.values["mic_utterances"], "0")
        XCTAssertEqual(document.values["mic_speakers"], "0")
        let capture = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))
        XCTAssertEqual(capture.sttEngine, SpeechTranscriptionEngineDescriptor.parakeetLocal.identifier)
        XCTAssertEqual(capture.diarizationEngine, "pyannote_offline")
        XCTAssertFalse(capture.utterances.isEmpty)
        XCTAssertFalse(capture.speakers.isEmpty)
        XCTAssertTrue(capture.speakers.allSatisfy { !$0.id.hasPrefix("mic_") })
        XCTAssertTrue(capture.utterances.allSatisfy { !$0.speakerId.hasPrefix("mic_") && !$0.text.isEmpty })
        let words = Set(capture.utterances.flatMap { Self.words($0.text) })
        XCTAssertGreaterThan(words.count, 5, "Real inference must produce meaningful speech, not an empty success artifact.")
        for expected in configuration.expectedWords {
            XCTAssertTrue(words.contains(expected), "Missing the synthetic fixture's expected word: \(expected)")
        }
        return capture
    }

    private func runExecutable(
        _ binary: URL, arguments: [String], root: URL, timeout: TimeInterval,
        expectSuccess: Bool = true, interrupt: Int32? = nil
    ) async throws -> ProcessResult {
        let fm = FileManager.default
        let output = root.appendingPathComponent("stdout-\(UUID().uuidString).txt")
        let errors = root.appendingPathComponent("stderr-\(UUID().uuidString).txt")
        guard fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure("Could not create private CLI test output files.")
        }
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        if ProcessInfo.processInfo.environment["TRANSCRIPTED_CLI_E2E_DENY_NETWORK"] == "1" {
            let sandbox = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            guard fm.isExecutableFile(atPath: sandbox.path) else {
                throw Failure("Network-denied E2E requested, but sandbox-exec is unavailable.")
            }
            process.executableURL = sandbox
            process.arguments = ["-p", "(version 1) (allow default) (deny network*)", binary.path] + arguments
        } else {
            process.executableURL = binary
            process.arguments = arguments
        }
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
        let childTemp = root.appendingPathComponent("child-tmp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: childTemp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        environment["TMPDIR"] = childTemp.path + "/"
        process.environment = environment
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var sentSignal = false
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            if let interrupt, !sentSignal {
                let progress = String(decoding: try Data(contentsOf: errors), as: UTF8.self)
                if progress.contains("Loading Parakeet models") {
                    // This phase follows normalization and signal-handler setup.
                    // Observe an actual owned job before exercising cleanup.
                    guard try ownedJobs(in: childTemp).isEmpty == false else {
                        throw Failure("CLI did not place its owned scratch job under the explicitly assigned TMPDIR.")
                    }
                    guard kill(process.processIdentifier, interrupt) == 0 else {
                        throw Failure("Could not send the requested cancellation signal to the CLI.")
                    }
                    sentSignal = true
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            throw Failure("CLI exceeded its \(Int(timeout))-second E2E timeout.")
        }
        let errorText = String(decoding: try Data(contentsOf: errors), as: UTF8.self)
        if interrupt != nil, !sentSignal {
            throw Failure("CLI exited before the requested model-load cancellation phase: \(errorText.suffix(4_000))")
        }
        guard !expectSuccess || (process.terminationReason == .exit && process.terminationStatus == 0) else {
            throw Failure("CLI failed with status \(process.terminationStatus): \(errorText.suffix(4_000))")
        }
        XCTAssertTrue(try ownedJobs(in: childTemp).isEmpty, "Every exited import must clean its private job directory.")
        return ProcessResult(stdout: try Data(contentsOf: output), stderr: errorText,
                             status: process.terminationStatus, reason: process.terminationReason)
    }

    private func importArguments(
        _ configuration: Configuration, input: URL, output: URL,
        models: URL? = nil, diarizer: URL? = nil, extra: [String]
    ) -> [String] {
        ["import-audio", input.path, "--output-dir", output.path,
         "--models-dir", (models ?? configuration.models).path,
         "--diarization-models-dir", (diarizer ?? configuration.diarizationModels).path,
         "--speaker-embedder", "wespeaker", "--no-download", "--json"] + extra
    }

    private func assertFailedWithoutCapture(_ result: ProcessResult, output: URL) throws {
        XCTAssertNotEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.reason, .exit, "A clean CLI error must not crash: \(result.stderr)")
        XCTAssertNil(try? JSONDecoder().decode(MeetingImportReceipt.self, from: result.stdout))
        XCTAssertTrue(result.stdout.isEmpty, "A failed import must not emit a success-shaped stdout payload.")
        XCTAssertFalse(result.stderr.isEmpty, "A failed import should explain the failure on stderr.")
        let entries = FileManager.default.enumerator(at: output, includingPropertiesForKeys: [.isRegularFileKey])
        let artifacts = (entries?.allObjects as? [URL] ?? []).filter {
            ["md", "wav", "m4a"].contains($0.pathExtension.lowercased()) || $0.lastPathComponent.hasPrefix(".transcripted-import-")
        }
        XCTAssertTrue(artifacts.isEmpty, "Failed import left an output artifact: \(artifacts.map(\.lastPathComponent))")
    }

    private func assertCancellation(signal: Int32) async throws {
        let configuration = try Configuration.fromEnvironment()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try copyFixture(configuration, into: root)
        let before = try FileProof(input)
        let output = root.appendingPathComponent("cancelled-output")
        let result = try await runExecutable(
            configuration.binary,
            arguments: importArguments(configuration, input: input, output: output, extra: ["--no-speaker-identification"]),
            root: root, timeout: 180, expectSuccess: false, interrupt: signal
        )
        XCTAssertEqual(result.status, 128 + signal, result.stderr)
        try assertFailedWithoutCapture(result, output: output)
        XCTAssertEqual(try FileProof(input), before)
    }

    private func ownedJobs(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("transcripted-cli-import-") }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImportAudioExecutableE2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func copyFixture(_ configuration: Configuration, into root: URL) throws -> URL {
        let input = root.appendingPathComponent("fixture ää.\(configuration.audio.pathExtension)")
        try FileManager.default.copyItem(at: configuration.audio, to: input)
        return input
    }

    private func writeSilentWAV(to url: URL, duration: TimeInterval) throws {
        let frames = AVAudioFrameCount(duration * 16_000)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { throw Failure("Could not allocate silent WAV fixture.") }
        buffer.frameLength = frames
        channel.update(repeating: 0, count: Int(frames))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private struct Configuration {
        let binary: URL
        let audio: URL
        let models: URL
        let diarizationModels: URL
        let expectedWords: Set<String>

        static func fromEnvironment() throws -> Configuration {
            let environment = ProcessInfo.processInfo.environment
            let keys = ["TRANSCRIPTED_CLI_E2E_BINARY", "TRANSCRIPTED_CLI_E2E_AUDIO",
                        "TRANSCRIPTED_CLI_E2E_MODELS", "TRANSCRIPTED_CLI_E2E_DIARIZATION"]
            guard keys.contains(where: { environment[$0] != nil }) else {
                throw XCTSkip("Real-model CLI E2E is opt-in; supply binary, synthetic audio, and both local model directories.")
            }
            let paths = try keys.map { key -> URL in
                guard let path = environment[key], !path.isEmpty else {
                    throw Failure("Partially configured real-model E2E: missing \(key).")
                }
                return URL(fileURLWithPath: path).standardizedFileURL
            }
            guard FileManager.default.isExecutableFile(atPath: paths[0].path) else {
                throw Failure("TRANSCRIPTED_CLI_E2E_BINARY must point to the built executable.")
            }
            _ = try MeetingImportModels.resolve(modelsDir: paths[2].path, diarizationModelsDir: paths[3].path, noDownload: true)
            return Configuration(binary: paths[0], audio: paths[1], models: paths[2], diarizationModels: paths[3],
                                 expectedWords: Set(ImportAudioExecutableE2ETests.words(environment["TRANSCRIPTED_CLI_E2E_EXPECTED_WORDS"] ?? "")))
        }
    }

    private struct FileProof: Equatable {
        let digest: Data
        let modificationDate: Date?
        let size: UInt64?
        let permissions: UInt16?

        init(_ url: URL) throws {
            digest = Data(SHA256.hash(data: try Data(contentsOf: url)))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            modificationDate = attributes[.modificationDate] as? Date
            size = (attributes[.size] as? NSNumber)?.uint64Value
            permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        }
    }

    private struct DatabaseProof: Equatable {
        let database: FileProof
        let wal: FileProof?

        init(_ url: URL) throws {
            database = try FileProof(url)
            let walURL = URL(fileURLWithPath: url.path + "-wal")
            wal = FileManager.default.fileExists(atPath: walURL.path) ? try FileProof(walURL) : nil
        }
    }

    private struct ProcessResult {
        let stdout: Data
        let stderr: String
        let status: Int32
        let reason: Process.TerminationReason
    }
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
#endif

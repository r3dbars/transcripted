import ArgumentParser
import Darwin
import Foundation
import TranscriptedCaptureKit

enum ImportedAudioSmokeMode {
    case fixtureOnly
    case producer(URL)
}

private struct ImportedAudioProducerReceipt: Decodable {
    let formatVersion: Int
    let transcript: String
    let retainedAudio: String
    let speechCalls: Int
    let diarizationCalls: Int
}

struct ImportedAudioSmoke: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imported-audio-smoke",
        abstract: "Run a deterministic imported-audio artifact smoke without native picker automation."
    )

    @Option(name: .long, help: "Directory for generated evidence. Defaults to a temporary directory.")
    var output: String?

    @Option(name: .long, help: "Output format: text or json")
    var format: OutputFormat = .text

    @Flag(name: .long, help: "Keep generated fixture files after the smoke finishes.")
    var preserve = false

    @Option(name: .long, help: "Core pipeline producer executable. Required unless --fixture-only is selected.")
    var producer: String?

    @Flag(name: .long, help: "Validate only a parser fixture; does not exercise the production import pipeline.")
    var fixtureOnly = false

    func validate() throws {
        guard fixtureOnly != (producer != nil) else {
            throw ValidationError("Choose --producer <executable> for Core pipeline evidence, or --fixture-only for parser fixture coverage.")
        }
    }

    func run() throws {
        try validate()
        let mode: ImportedAudioSmokeMode = fixtureOnly
            ? .fixtureOnly : .producer(URL(fileURLWithPath: producer!))
        let runner = ImportedAudioSmokeRunner(
            outputDirectory: output.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL },
            preserve: preserve,
            mode: mode
        )
        let results = try runner.run()
        try runValidation(results: results, format: format)
    }
}

struct ImportedAudioSmokeRunner {
    private let outputDirectory: URL?
    private let preserve: Bool
    private let fileManager: FileManager
    private let mode: ImportedAudioSmokeMode

    init(outputDirectory: URL? = nil, preserve: Bool = false, mode: ImportedAudioSmokeMode, fileManager: FileManager = .default) {
        self.outputDirectory = outputDirectory
        self.preserve = preserve
        self.fileManager = fileManager
        self.mode = mode
    }

    func run() throws -> [ValidationResult] {
        let ownedParent = (outputDirectory ?? fileManager.temporaryDirectory)
            .resolvingSymlinksInPath().standardizedFileURL
        let prefix = "transcripted-imported-audio-smoke-"
        let root = ownedParent.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        let shouldRemoveRoot = outputDirectory == nil && !preserve
        var cleanupAttempted = false
        func cleanup() throws {
            guard shouldRemoveRoot, !cleanupAttempted else { return }
            cleanupAttempted = true
            let parent = root.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard parent.path == ownedParent.path,
                  root.lastPathComponent.hasPrefix(prefix),
                  UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil else {
                throw ValidationError("Refusing cleanup outside the owned imported-audio evidence root.")
            }
            do {
                let type = try fileManager.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType
                guard type == .typeDirectory else {
                    throw ValidationError("Imported-audio evidence root is not a real directory; cleanup refused.")
                }
                try fileManager.removeItem(at: root)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                // Nothing was created, or the owned root is already gone.
            }
        }
        do {
            let results = try runEvidence(in: root)
            try cleanup()
            return results
        } catch {
            try cleanup()
            throw error
        }
    }

    private func runEvidence(in root: URL) throws -> [ValidationResult] {
        let sourceAudio = root.appendingPathComponent("source/Imported Partner Brief.wav", isDirectory: false)
        let meetingsDir = root.appendingPathComponent("captures/meetings", isDirectory: true)
        var transcriptURL = meetingsDir.appendingPathComponent("Imported Partner Brief.md", isDirectory: false)
        let retainedAudioDir = meetingsDir
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("Imported Partner Brief_audio", isDirectory: true)
        var retainedAudio = retainedAudioDir.appendingPathComponent("recording.wav", isDirectory: false)

        try fileManager.createDirectory(at: sourceAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "core-import-smoke-v1".write(to: root.appendingPathComponent(".producer-root"), atomically: true, encoding: .utf8)
        try writeSyntheticWAV(to: sourceAudio)

        var results: [ValidationResult] = [.pass("imported-audio/source-fixture", target: sourceAudio.lastPathComponent)]
        switch mode {
        case .fixtureOnly:
            try fileManager.createDirectory(at: retainedAudioDir, withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceAudio, to: retainedAudio)
            try importedMeetingMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
            results.append(.warn("imported-audio/fixture-only", target: "parser fixture", detail: "No production import pipeline was executed."))
        case .producer(let executable):
            (transcriptURL, retainedAudio) = try produceArtifacts(executable: executable, root: root, sourceAudio: sourceAudio)
            results.append(.pass("imported-audio/core-pipeline", target: "Core import/save/retention with synthetic speech engines"))
        }
        results.append(.pass("imported-audio/retained-audio", target: retainedAudio.lastPathComponent))

        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        guard let document = CaptureMarkdownParser.parseFrontmatter(from: markdown) else {
            return results + [
                .fail("imported-audio/frontmatter", target: transcriptURL.lastPathComponent, detail: "Generated imported meeting markdown has no frontmatter.")
            ]
        }

        results.append(contentsOf: validateImportedFrontmatter(document.values, transcriptURL: transcriptURL))

        guard let meeting = CaptureMarkdownParser.parseMeeting(from: markdown) else {
            return results + [
                .fail("imported-audio/parser", target: transcriptURL.lastPathComponent, detail: "CaptureMarkdownParser could not parse the imported meeting.")
            ]
        }
        results.append(.pass("imported-audio/parser", target: "\(meeting.utterances.count) utterance(s)"))

        let micSpeakerCount = meeting.speakers.filter { $0.id.hasPrefix("mic_") }.count
        let systemSpeakerCount = meeting.speakers.filter { $0.id.hasPrefix("system_") }.count
        if micSpeakerCount == 0 && systemSpeakerCount == 1 {
            results.append(.pass("imported-audio/speaker-channel", target: "system-only"))
        } else {
            results.append(.fail(
                "imported-audio/speaker-channel",
                target: "mic=\(micSpeakerCount), system=\(systemSpeakerCount)",
                detail: "Single-file imported audio should parse as system-only speaker content."
            ))
        }

        results.append(contentsOf: validateRetainedAudio(transcriptURL: transcriptURL, retainedAudio: retainedAudio))

        if try Data(contentsOf: sourceAudio) == Data(contentsOf: retainedAudio) {
            results.append(.pass("imported-audio/retained-audio-bytes", target: "source preserved"))
        } else {
            results.append(.fail("imported-audio/retained-audio-bytes", target: "recording.wav", detail: "Retained audio differs from the synthetic input."))
        }
        if case .producer = mode, document.values["imported_at"] == nil {
            results.append(.fail("imported-audio/imported-at", target: transcriptURL.lastPathComponent, detail: "Core import did not record imported_at."))
        }

        let validatorFailures = TranscriptValidator(directory: transcriptURL.deletingLastPathComponent())
            .validate()
            .filter { $0.status == .fail }
        if validatorFailures.isEmpty {
            results.append(.pass("imported-audio/transcript-validator", target: transcriptURL.lastPathComponent))
        } else {
            let detail = validatorFailures.map { "\($0.check): \($0.detail ?? $0.target)" }.joined(separator: "; ")
            results.append(.fail("imported-audio/transcript-validator", target: transcriptURL.lastPathComponent, detail: detail))
        }

        if preserve || outputDirectory != nil {
            results.append(.pass("imported-audio/evidence-root", target: root.path))
        }

        return results
    }

    private func produceArtifacts(executable: URL, root: URL, sourceAudio: URL) throws -> (URL, URL) {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--root", root.path, "--source", sourceAudio.path]
        var environment = ProcessInfo.processInfo.environment
        environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
        environment["TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS"] = "1"
        process.environment = environment
        // Producer diagnostics must never corrupt this command's JSON report.
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ExitCode(process.terminationStatus == 3 ? 3 : 1)
        }
        let receipt = try JSONDecoder().decode(
            ImportedAudioProducerReceipt.self,
            from: Data(contentsOf: root.appendingPathComponent("producer-receipt.json"))
        )
        guard receipt.formatVersion == 1, receipt.speechCalls > 0, receipt.diarizationCalls > 0 else {
            throw ValidationError("Producer did not confirm the Core synthetic-engine pipeline ran.")
        }
        func ownedFile(_ relative: String) throws -> URL {
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
            let candidate = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
            guard !relative.hasPrefix("/"), candidate.path.hasPrefix(canonicalRoot.path + "/"),
                  fileManager.fileExists(atPath: candidate.path) else {
                throw ValidationError("Producer artifact is missing or outside the owned evidence root.")
            }
            return candidate
        }
        return try (ownedFile(receipt.transcript), ownedFile(receipt.retainedAudio))
    }

    private func validateImportedFrontmatter(_ values: [String: String], transcriptURL: URL) -> [ValidationResult] {
        let target = transcriptURL.lastPathComponent
        var results: [ValidationResult] = []

        func expect(_ check: String, _ actual: String?, equals expected: String) {
            if actual == expected {
                results.append(.pass(check, target: expected))
            } else {
                results.append(.fail(check, target: target, detail: "Expected \(expected), got \(actual ?? "nil")."))
            }
        }

        expect("imported-audio/capture-type", values["capture_type"], equals: "meeting")
        expect("imported-audio/sources", values["sources"], equals: "system_audio")
        expect("imported-audio/mic-utterances", values["mic_utterances"], equals: "0")
        expect("imported-audio/system-utterances", values["system_utterances"], equals: "1")
        return results
    }

    private func validateRetainedAudio(transcriptURL: URL, retainedAudio: URL) -> [ValidationResult] {
        let expectedParent = transcriptURL.deletingLastPathComponent()
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("\(transcriptURL.deletingPathExtension().lastPathComponent)_audio", isDirectory: true)
        guard retainedAudio.deletingLastPathComponent().standardizedFileURL == expectedParent.standardizedFileURL else {
            return [
                .fail(
                    "imported-audio/retained-audio-location",
                    target: retainedAudio.path,
                    detail: "Retained audio should live beside the imported meeting markdown under audio/<stem>_audio/."
                )
            ]
        }

        guard fileManager.fileExists(atPath: retainedAudio.path) else {
            return [
                .fail("imported-audio/retained-audio-location", target: retainedAudio.path, detail: "Retained imported audio file is missing.")
            ]
        }

        return [.pass("imported-audio/retained-audio-location", target: retainedAudio.lastPathComponent)]
    }

    private func writeSyntheticWAV(to url: URL) throws {
        let sampleRate = 16_000
        let durationSeconds = 3
        let samples = sampleRate * durationSeconds
        var pcm = Data(capacity: samples * 2)
        for index in 0..<samples {
            let phase = Double(index) / Double(sampleRate)
            let value = Int16((sin(phase * 2 * Double.pi * 440) * 8_000).rounded())
            var littleEndian = value.littleEndian
            pcm.append(Data(bytes: &littleEndian, count: MemoryLayout<Int16>.size))
        }

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(littleEndianUInt32(UInt32(36 + pcm.count)))
        data.append("WAVEfmt ".data(using: .ascii)!)
        data.append(littleEndianUInt32(16))
        data.append(littleEndianUInt16(1))
        data.append(littleEndianUInt16(1))
        data.append(littleEndianUInt32(UInt32(sampleRate)))
        data.append(littleEndianUInt32(UInt32(sampleRate * 2)))
        data.append(littleEndianUInt16(2))
        data.append(littleEndianUInt16(16))
        data.append("data".data(using: .ascii)!)
        data.append(littleEndianUInt32(UInt32(pcm.count)))
        data.append(pcm)
        try data.write(to: url, options: .atomic)
    }

    private func littleEndianUInt16(_ value: UInt16) -> Data {
        var copy = value.littleEndian
        return Data(bytes: &copy, count: MemoryLayout<UInt16>.size)
    }

    private func littleEndianUInt32(_ value: UInt32) -> Data {
        var copy = value.littleEndian
        return Data(bytes: &copy, count: MemoryLayout<UInt32>.size)
    }

    private var importedMeetingMarkdown: String {
        """
        ---
        capture_id: "22222222-2222-2222-2222-222222222222"
        transcript_id: "22222222-2222-2222-2222-222222222222"
        title: "Imported Partner Brief"
        capture_type: meeting
        date: 2026-06-22
        time: 16:15:00
        duration: "00:00:03"
        processing_time: "0.3s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [system_audio]
        mic_utterances: 0
        system_utterances: 1
        mic_speakers: 0
        system_speakers: 1
        total_word_count: 11
        speakers:
          - id: "0"
            channel: system
            name: "Speaker 1"
            confidence: low
            source: imported_audio_smoke
        ---

        # Imported Partner Brief

        Recorded Jun 22, 2026 at 4:15 PM  -  3 sec  -  11 words  -  1 turn

        ## Transcript

        **00:00**  [System/Speaker 1]
        The imported recording should save as one searchable meeting note.
        """
    }
}

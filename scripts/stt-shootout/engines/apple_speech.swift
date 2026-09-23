// apple_speech.swift
// Apple Speech (macOS 26 SpeechAnalyzer + SpeechTranscriber) runner for the
// STT shootout. Same result JSON as engines/py_engines.py. The shootout
// compiles it with: xcrun swiftc -O -parse-as-library apple_speech.swift
//
// Mirrors how PR #1776's AppleSpeechEngine drives Apple's engine: one
// SpeechAnalyzer per transcription, finalized results only. Long files are
// streamed to the analyzer in 30-second buffers instead of one giant buffer.

@preconcurrency import AVFoundation
import Foundation
import Speech

enum BenchError: Error, CustomStringConvertible {
    case usage(String)
    case unsupportedLocale(String)
    case conversion

    var description: String {
        switch self {
        case .usage(let message): return message
        case .unsupportedLocale(let id): return "Apple Speech doesn't support \(id) on this Mac"
        case .conversion: return "audio conversion failed"
        }
    }
}

struct Options {
    var audio = ""
    var clip = ""
    var out = ""
    var runs = 3
    var locale = "en-US"

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 1
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw BenchError.usage("missing value for \(arguments[index - 1])") }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--audio": options.audio = try value()
            case "--clip": options.clip = try value()
            case "--out": options.out = try value()
            case "--runs": options.runs = Int(try value()) ?? 3
            case "--locale": options.locale = try value()
            default: throw BenchError.usage("unknown argument \(arguments[index])")
            }
            index += 1
        }
        guard !options.audio.isEmpty, !options.clip.isEmpty, !options.out.isEmpty else {
            throw BenchError.usage("usage: apple-speech-bench --audio F --clip F --out F [--runs N] [--locale en-US]")
        }
        return options
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("apple-speech: \(message)\n".utf8))
}

func now() -> Double { Date().timeIntervalSinceReferenceDate }

func makeTranscriber(locale: Locale) -> SpeechTranscriber {
    SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
}

func resolveLocale(_ identifier: String) async throws -> Locale {
    let supported = await SpeechTranscriber.supportedLocales.map(\.identifier)
    let wanted = identifier.replacingOccurrences(of: "_", with: "-")
    if let exact = supported.first(where: { $0.replacingOccurrences(of: "_", with: "-") == wanted }) {
        return Locale(identifier: exact)
    }
    let language = wanted.split(separator: "-").first.map(String.init) ?? wanted
    if let sameLanguage = supported.sorted().first(where: { $0.hasPrefix(language) }) {
        return Locale(identifier: sameLanguage)
    }
    throw BenchError.unsupportedLocale(identifier)
}

func ensureAssets(locale: Locale) async throws {
    let transcriber = makeTranscriber(locale: locale)
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        log("downloading Apple's \(locale.identifier) speech files...")
        try await request.downloadAndInstall()
    }
}

func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    if buffer.format == format { return buffer }
    guard let converter = AVAudioConverter(from: buffer.format, to: format) else { throw BenchError.conversion }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1_024
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw BenchError.conversion }
    var consumed = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
        if consumed {
            inputStatus.pointee = .endOfStream
            return nil
        }
        consumed = true
        inputStatus.pointee = .haveData
        return buffer
    }
    guard status != .error, conversionError == nil else { throw BenchError.conversion }
    return output
}

/// Transcribes one file with a fresh analyzer, like the app does per segment.
func transcribe(url: URL, locale: Locale) async throws -> String {
    let transcriber = makeTranscriber(locale: locale)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let file = try AVAudioFile(forReading: url)
    let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

    let collector = Task { () throws -> [String] in
        var parts: [String] = []
        for try await result in transcriber.results where result.isFinal {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
        }
        return parts
    }

    let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
    let feeder = Task { () throws -> Void in
        defer { inputBuilder.finish() }
        let chunkFrames = AVAudioFrameCount(file.processingFormat.sampleRate * 30)
        while file.framePosition < file.length {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
                throw BenchError.conversion
            }
            try file.read(into: chunk, frameCount: chunkFrames)
            if chunk.frameLength == 0 { break }
            let ready = try analyzerFormat.map { try convert(chunk, to: $0) } ?? chunk
            inputBuilder.yield(AnalyzerInput(buffer: ready))
        }
    }

    do {
        if let lastSampleTime = try await analyzer.analyzeSequence(inputSequence) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        try await feeder.value
    } catch {
        feeder.cancel()
        collector.cancel()
        await analyzer.cancelAndFinishNow()
        throw error
    }
    return try await collector.value.joined(separator: " ")
}

@main
struct AppleSpeechBench {
    static func main() async {
        do {
            let options = try Options.parse(CommandLine.arguments)
            let audioURL = URL(fileURLWithPath: options.audio)
            let clipURL = URL(fileURLWithPath: options.clip)

            let loadStart = now()
            let locale = try await resolveLocale(options.locale)
            try await ensureAssets(locale: locale)
            let loadSeconds = now() - loadStart
            log("ready (\(locale.identifier)) in \(String(format: "%.2f", loadSeconds))s")

            var clipTimes: [Double] = []
            var clipText = ""
            for run in 0...max(0, options.runs) {
                let start = now()
                clipText = try await transcribe(url: clipURL, locale: locale)
                clipTimes.append(now() - start)
                log("clip run \(run): \(String(format: "%.3f", clipTimes.last!))s")
            }

            log("transcribing the full test file...")
            let fullStart = now()
            let text = try await transcribe(url: audioURL, locale: locale)
            let fullSeconds = now() - fullStart
            log("full file in \(String(format: "%.1f", fullSeconds))s")

            let result: [String: Any] = [
                "load_seconds": loadSeconds,
                "clip_cold_seconds": clipTimes[0],
                "clip_warm_seconds": Array(clipTimes.dropFirst()),
                "full_seconds": fullSeconds,
                "text": text,
                "clip_text": clipText,
                "locale": locale.identifier,
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: options.out))
        } catch {
            log("failed: \(error)")
            exit(1)
        }
    }
}

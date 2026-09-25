// WhisperKit (Core ML) runner for the STT shootout: the same engine and
// decode options the app's Whisper model choices use (Sources/Speech/WhisperEngine.swift).
// Same result JSON as engines/py_engines.py.

import AVFoundation
import Foundation
import WhisperKit

func log(_ message: String) {
    FileHandle.standardError.write(Data("whisperkit: \(message)\n".utf8))
}

func now() -> Double { Date().timeIntervalSinceReferenceDate }

func argument(_ name: String, default fallback: String? = nil) -> String {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: name), index + 1 < args.count { return args[index + 1] }
    if let fallback { return fallback }
    log("missing \(name)")
    exit(2)
}

/// 16 kHz mono 16-bit WAV (what the shootout writes) as floats.
func loadSamples(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "whisperkit-bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "can't allocate audio buffer"])
    }
    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

func transcribe(_ pipe: WhisperKit, _ samples: [Float], chunked: Bool) async throws -> String {
    let results = try await pipe.transcribe(
        audioArray: samples,
        decodeOptions: DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // The app decodes one segment at a time; for the hour-long file,
            // WhisperKit's own VAD chunking with parallel workers is its fast path.
            concurrentWorkerCount: chunked ? 4 : 1,
            chunkingStrategy: chunked ? .vad : nil
        )
    )
    return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

let variant = argument("--model", default: "large-v3-v20240930_turbo_632MB")
let downloadBase = URL(fileURLWithPath: argument("--models-dir"), isDirectory: true)
let runs = Int(argument("--runs", default: "3")) ?? 3

do {
    let audio = try loadSamples(argument("--audio"))
    let clip = try loadSamples(argument("--clip"))

    log("downloading \(variant) if needed...")
    let modelFolder = try await WhisperKit.download(
        variant: variant,
        downloadBase: downloadBase,
        useBackgroundSession: false,
        from: "argmaxinc/whisperkit-coreml"
    )

    let loadStart = now()
    let pipe = try await WhisperKit(WhisperKitConfig(
        model: variant,
        downloadBase: downloadBase,
        modelRepo: "argmaxinc/whisperkit-coreml",
        modelFolder: modelFolder.path,
        verbose: false,
        logLevel: .error,
        prewarm: false,
        load: true,
        download: false,
        useBackgroundDownloadSession: false
    ))
    let loadSeconds = now() - loadStart
    log("loaded in \(String(format: "%.2f", loadSeconds))s")

    var clipTimes: [Double] = []
    var clipText = ""
    for run in 0...max(0, runs) {
        let start = now()
        clipText = try await transcribe(pipe, clip, chunked: false)
        clipTimes.append(now() - start)
        log("clip run \(run): \(String(format: "%.3f", clipTimes.last!))s")
    }

    log("transcribing the full test file...")
    let fullStart = now()
    let text = try await transcribe(pipe, audio, chunked: true)
    let fullSeconds = now() - fullStart
    log("full file in \(String(format: "%.1f", fullSeconds))s")

    let result: [String: Any] = [
        "load_seconds": loadSeconds,
        "clip_cold_seconds": clipTimes[0],
        "clip_warm_seconds": Array(clipTimes.dropFirst()),
        "full_seconds": fullSeconds,
        "text": text,
        "clip_text": clipText,
        "model": variant,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
        .write(to: URL(fileURLWithPath: argument("--out")))
} catch {
    log("failed: \(error)")
    exit(1)
}

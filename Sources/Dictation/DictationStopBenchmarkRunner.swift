import AppKit
@preconcurrency import AVFoundation
import Darwin
import FluidAudio
import Foundation
import TranscriptedCore

@MainActor
enum DictationStopBenchmarkRunner {
    private static let iso8601 = ISO8601DateFormatter()

    static func runFromEnvironmentIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["TRANSCRIPTED_DICTATION_STOP_BENCH_AUDIO_DIR"] != nil else {
            return false
        }

        Task { @MainActor in
            let status = await run()
            fflush(stdout)
            fflush(stderr)
            exit(status)
        }
        return true
    }

    private static func run() async -> Int32 {
        do {
            let config = try Configuration(environment: ProcessInfo.processInfo.environment)
            try FileManager.default.createDirectory(
                at: config.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(at: config.saveDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: config.outputURL)

            let cases = try benchmarkCases(in: config.audioDirectory)
            guard !cases.isEmpty else {
                throw BenchmarkError("No .wav fixtures found in \(config.audioDirectory.path)")
            }

            let engine = ParakeetEngine()
            let initStarted = CFAbsoluteTimeGetCurrent()
            await engine.initialize()
            let modelInitSeconds = CFAbsoluteTimeGetCurrent() - initStarted
            guard engine.isModelLoaded else {
                throw BenchmarkError("Parakeet model did not load")
            }

            try appendJSONLine([
                "record_type": "run_start",
                "timestamp": iso8601.string(from: Date()),
                "variant": config.variant.rawValue,
                "iterations": config.iterations,
                "case_count": cases.count,
                "model_init_s": rounded(modelInitSeconds),
                "finalization_order": DictationStopFinalizationPolicy.order.rawValue,
                "simulate_auto_enter": config.simulateAutoEnter,
                "auto_enter_delay_s": rounded(Double(TranscriptedConstants.dictationAutoEnterDelay) / 1_000_000_000.0),
                "chunk_seconds": rounded(config.chunkSeconds)
            ], to: config.outputURL)

            for iteration in 1...config.iterations {
                for benchmarkCase in cases {
                    try await runCase(
                        benchmarkCase,
                        iteration: iteration,
                        engine: engine,
                        config: config
                    )
                }
            }

            return 0
        } catch {
            fputs("Dictation stop benchmark failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func runCase(
        _ benchmarkCase: BenchmarkCase,
        iteration: Int,
        engine: ParakeetEngine,
        config: Configuration
    ) async throws {
        let loaded = try AudioResampler.loadWAV(url: benchmarkCase.url)
        let audioDuration = Double(loaded.samples.count) / loaded.sampleRate
        let stopStarted = CFAbsoluteTimeGetCurrent()
        let preprocessed: PreprocessedAudio
        let rawText: String?

        switch config.variant {
        case .native:
            preprocessed = PreprocessedAudio(
                samples: loaded.samples,
                sampleRate: loaded.sampleRate,
                preprocessSeconds: 0,
                resampledSampleCount: estimatedResampledSampleCount(
                    inputCount: loaded.samples.count,
                    inputRate: loaded.sampleRate
                )
            )
            engine.loadRecordedSamplesForDictationBenchmark(preprocessed.samples, sampleRate: preprocessed.sampleRate)
            rawText = await engine.transcribe()
        case .preResampled:
            let preprocessStarted = CFAbsoluteTimeGetCurrent()
            let resampled = AudioResampler.resample(
                loaded.samples,
                from: loaded.sampleRate,
                to: TranscriptedConstants.parakeetSampleRate
            )
            preprocessed = PreprocessedAudio(
                samples: resampled,
                sampleRate: TranscriptedConstants.parakeetSampleRate,
                preprocessSeconds: CFAbsoluteTimeGetCurrent() - preprocessStarted,
                resampledSampleCount: resampled.count
            )
            engine.loadRecordedSamplesForDictationBenchmark(preprocessed.samples, sampleRate: preprocessed.sampleRate)
            rawText = await engine.transcribe()
        case .chunked:
            let preprocessStarted = CFAbsoluteTimeGetCurrent()
            let resampled = AudioResampler.resample(
                loaded.samples,
                from: loaded.sampleRate,
                to: TranscriptedConstants.parakeetSampleRate
            )
            preprocessed = PreprocessedAudio(
                samples: resampled,
                sampleRate: TranscriptedConstants.parakeetSampleRate,
                preprocessSeconds: CFAbsoluteTimeGetCurrent() - preprocessStarted,
                resampledSampleCount: resampled.count
            )
            rawText = try await transcribeInChunks(
                samples16k: preprocessed.samples,
                chunkSeconds: config.chunkSeconds,
                engine: engine
            )
        }

        let cleanupResult = rawText.map { text in
            if DictationCleanupPreferences.isEnabled() {
                return DictationFillerCleanupPolicy.clean(text)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return DictationFillerCleanupResult(text: trimmed, removedCount: 0, changed: trimmed != text)
        }
        let finalText = cleanupResult?.text ?? ""
        let textReadyAt = CFAbsoluteTimeGetCurrent()
        let stopToText = textReadyAt - stopStarted
        let wordCount = finalText.split(whereSeparator: \.isWhitespace).count

        guard !finalText.isEmpty else {
            try appendJSONLine(basePayload(
                benchmarkCase: benchmarkCase,
                iteration: iteration,
                config: config,
                loaded: loaded,
                audioDuration: audioDuration,
                preprocessed: preprocessed,
                stopToText: stopToText
            ).merging([
                "no_speech": true,
                "saved": false,
                "delivery": "no_speech",
                "chars": 0,
                "words": 0,
                "text_hash": "",
                "stop_to_delivery_s": rounded(stopToText)
            ]) { _, new in new }, to: config.outputURL)
            return
        }

        let pastedAt = CFAbsoluteTimeGetCurrent()
        let savedAt: CFAbsoluteTime
        switch DictationStopFinalizationPolicy.order {
        case .saveAfterAutoEnter:
            if config.simulateAutoEnter {
                try? await Task.sleep(nanoseconds: TranscriptedConstants.dictationAutoEnterDelay)
            }
            try DictationTranscriptStore.save(
                text: finalText,
                sourceApp: nil,
                delivery: .pasted,
                directory: config.saveDirectory
            )
            savedAt = CFAbsoluteTimeGetCurrent()
        case .saveBeforeAutoEnter:
            try DictationTranscriptStore.save(
                text: finalText,
                sourceApp: nil,
                delivery: .pasted,
                directory: config.saveDirectory
            )
            savedAt = CFAbsoluteTimeGetCurrent()
            if config.simulateAutoEnter {
                try? await Task.sleep(nanoseconds: TranscriptedConstants.dictationAutoEnterDelay)
            }
        }
        let deliveredAt = CFAbsoluteTimeGetCurrent()

        try appendJSONLine(basePayload(
            benchmarkCase: benchmarkCase,
            iteration: iteration,
            config: config,
            loaded: loaded,
            audioDuration: audioDuration,
            preprocessed: preprocessed,
            stopToText: stopToText
        ).merging([
            "no_speech": false,
            "saved": true,
            "delivery": "pasted",
            "chars": finalText.count,
            "words": wordCount,
            "text_hash": stableHash(finalText),
            "cleanup_removed": cleanupResult?.removedCount ?? 0,
            "stop_to_pasted_s": rounded(pastedAt - stopStarted),
            "stop_to_saved_s": rounded(savedAt - stopStarted),
            "stop_to_delivery_s": rounded(deliveredAt - stopStarted)
        ]) { _, new in new }, to: config.outputURL)
    }

    private static func transcribeInChunks(
        samples16k: [Float],
        chunkSeconds: Double,
        engine: ParakeetEngine
    ) async throws -> String {
        guard !samples16k.isEmpty else { return "" }
        let chunkSize = max(1, Int(chunkSeconds * TranscriptedConstants.parakeetSampleRate))
        var pieces: [String] = []
        var start = 0
        while start < samples16k.count {
            let end = min(start + chunkSize, samples16k.count)
            let text = try await engine.transcribeSamples(
                Array(samples16k[start..<end]),
                source: .microphone
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                pieces.append(text)
            }
            start = end
        }
        return pieces.joined(separator: " ")
    }

    private static func benchmarkCases(in directory: URL) throws -> [BenchmarkCase] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { url in
            BenchmarkCase(id: url.deletingPathExtension().lastPathComponent, url: url)
        }
    }

    private static func basePayload(
        benchmarkCase: BenchmarkCase,
        iteration: Int,
        config: Configuration,
        loaded: (samples: [Float], sampleRate: Double),
        audioDuration: Double,
        preprocessed: PreprocessedAudio,
        stopToText: Double
    ) -> [String: Any] {
        [
            "record_type": "case_result",
            "timestamp": iso8601.string(from: Date()),
            "case_id": benchmarkCase.id,
            "iteration": iteration,
            "variant": config.variant.rawValue,
            "finalization_order": DictationStopFinalizationPolicy.order.rawValue,
            "simulate_auto_enter": config.simulateAutoEnter,
            "audio_duration_s": rounded(audioDuration),
            "input_sample_rate_hz": rounded(loaded.sampleRate),
            "native_samples": loaded.samples.count,
            "bench_sample_rate_hz": rounded(preprocessed.sampleRate),
            "bench_samples": preprocessed.samples.count,
            "resampled_samples": preprocessed.resampledSampleCount,
            "preprocess_s": rounded(preprocessed.preprocessSeconds),
            "stop_to_text_s": rounded(stopToText)
        ]
    }

    private static func estimatedResampledSampleCount(inputCount: Int, inputRate: Double) -> Int {
        guard inputRate > 0 else { return 0 }
        return Int(Double(inputCount) / (inputRate / TranscriptedConstants.parakeetSampleRate))
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func rounded(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 1000).rounded() / 1000
    }

    private static func appendJSONLine(_ payload: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
    }

    private struct BenchmarkCase {
        let id: String
        let url: URL
    }

    private struct PreprocessedAudio {
        let samples: [Float]
        let sampleRate: Double
        let preprocessSeconds: Double
        let resampledSampleCount: Int
    }

    private enum Variant: String {
        case native
        case preResampled = "pre_resampled"
        case chunked
    }

    private struct Configuration {
        let audioDirectory: URL
        let outputURL: URL
        let saveDirectory: URL
        let iterations: Int
        let variant: Variant
        let simulateAutoEnter: Bool
        let chunkSeconds: Double

        init(environment: [String: String]) throws {
            guard let audioDir = environment["TRANSCRIPTED_DICTATION_STOP_BENCH_AUDIO_DIR"] else {
                throw BenchmarkError("Missing TRANSCRIPTED_DICTATION_STOP_BENCH_AUDIO_DIR")
            }
            guard let output = environment["TRANSCRIPTED_DICTATION_STOP_BENCH_OUTPUT"] else {
                throw BenchmarkError("Missing TRANSCRIPTED_DICTATION_STOP_BENCH_OUTPUT")
            }
            let saveDir = environment["TRANSCRIPTED_DICTATION_STOP_BENCH_SAVE_DIR"]
                ?? URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("saved").path
            let iterationValue = environment["TRANSCRIPTED_DICTATION_STOP_BENCH_ITERATIONS"].flatMap(Int.init) ?? 3
            let variantValue = environment["TRANSCRIPTED_DICTATION_STOP_BENCH_VARIANT"] ?? Variant.native.rawValue
            guard let variant = Variant(rawValue: variantValue) else {
                throw BenchmarkError("Unknown benchmark variant: \(variantValue)")
            }

            audioDirectory = URL(fileURLWithPath: audioDir).standardizedFileURL
            outputURL = URL(fileURLWithPath: output).standardizedFileURL
            saveDirectory = URL(fileURLWithPath: saveDir).standardizedFileURL
            iterations = max(1, iterationValue)
            self.variant = variant
            simulateAutoEnter = environment["TRANSCRIPTED_DICTATION_STOP_BENCH_AUTO_ENTER"] != "0"
            chunkSeconds = environment["TRANSCRIPTED_DICTATION_STOP_BENCH_CHUNK_SECONDS"].flatMap(Double.init) ?? 30
        }
    }

    private struct BenchmarkError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }
}

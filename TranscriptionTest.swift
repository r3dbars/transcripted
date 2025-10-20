#!/usr/bin/env swift

import Foundation
import AVFoundation
import Speech

// Simple test script to transcribe audio files and measure quality vs duration
// Usage: swift TranscriptionTest.swift

@available(macOS 13.0, *)
class TranscriptionTester {

    func transcribeFile(at url: URL) async throws -> (text: String, duration: TimeInterval, charCount: Int) {
        print("\n📝 Transcribing: \(url.lastPathComponent)")

        // Get audio duration
        let audioFile = try AVAudioFile(forReading: url)
        let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        print("   Duration: \(String(format: "%.1f", duration))s")

        let fileFormat = audioFile.processingFormat
        print("   Format: \(fileFormat.sampleRate)Hz \(fileFormat.channelCount)ch")

        // Create transcriber (on-device, same as app)
        let transcriber = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
        guard let recognizer = transcriber else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create recognizer"])
        }

        // Create recognition request
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true

        // Perform recognition
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let result = result, result.isFinal else {
                    return
                }

                let text = result.bestTranscription.formattedString
                let charCount = text.count
                continuation.resume(returning: (text, duration, charCount))
            }
        }
    }

    func runTests() async {
        let testFiles = [
            "/Users/justin.betker/Documents/test_1min.wav",
            "/Users/justin.betker/Documents/test_5min.wav",
            "/Users/justin.betker/Documents/test_10min.wav",
            "/Users/justin.betker/Documents/test_15min.wav",
            "/Users/justin.betker/Documents/test_18min.wav"
        ]

        print("🧪 Starting Transcription Duration Tests")
        print(String(repeating: "=", count: 60))

        var results: [(file: String, duration: TimeInterval, chars: Int, charsPerMin: Double)] = []

        for filePath in testFiles {
            let url = URL(fileURLWithPath: filePath)

            guard FileManager.default.fileExists(atPath: filePath) else {
                print("⚠️  File not found: \(url.lastPathComponent)")
                continue
            }

            do {
                let startTime = Date()
                let result = try await transcribeFile(at: url)
                let elapsed = Date().timeIntervalSince(startTime)

                let charsPerMin = (Double(result.charCount) / result.duration) * 60.0

                print("   ✅ Transcribed: \(result.charCount) characters")
                print("   📊 Rate: \(String(format: "%.1f", charsPerMin)) chars/minute")
                print("   ⏱️  Processing time: \(String(format: "%.1f", elapsed))s")

                results.append((
                    file: url.lastPathComponent,
                    duration: result.duration,
                    chars: result.charCount,
                    charsPerMin: charsPerMin
                ))

            } catch {
                print("   ❌ Error: \(error.localizedDescription)")
            }
        }

        // Print summary
        print("\n" + String(repeating: "=", count: 60))
        print("📊 SUMMARY")
        print(String(repeating: "=", count: 60))

        for result in results {
            print("\(result.file):")
            print("  Duration: \(String(format: "%.1f", result.duration))s")
            print("  Characters: \(result.chars)")
            print("  Rate: \(String(format: "%.1f", result.charsPerMin)) chars/min")
            print("")
        }

        // Analyze degradation
        if results.count >= 2 {
            print("\n📉 DEGRADATION ANALYSIS")
            print(String(repeating: "-", count: 60))

            let baseline = results[0].charsPerMin
            for (index, result) in results.enumerated() {
                if index == 0 {
                    print("\(result.file): BASELINE (\(String(format: "%.1f", baseline)) chars/min)")
                } else {
                    let degradation = ((baseline - result.charsPerMin) / baseline) * 100.0
                    print("\(result.file): \(String(format: "%+.1f%%", -degradation)) vs baseline")
                }
            }
        }
    }
}

// Run tests
if #available(macOS 13.0, *) {
    Task {
        let tester = TranscriptionTester()
        await tester.runTests()
        exit(0)
    }

    RunLoop.main.run()
} else {
    print("❌ Requires macOS 13.0 or later")
    exit(1)
}

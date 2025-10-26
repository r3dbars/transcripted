import Foundation
import Speech
@preconcurrency import AVFoundation

struct TimestampedSegment {
    let timestamp: TimeInterval
    let source: String  // "Mic" or "System Audio"
    let text: String
}

@available(macOS 26.0, *)
class Transcription: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var error: String?
    @Published var processingStatus: String = ""
    @Published var lastSavedFileURL: URL?

    init() {}

    /// Main entry point: Transcribe both audio files and save to markdown
    /// - Parameters:
    ///   - micURL: Mic audio file URL
    ///   - systemURL: System audio file URL (optional)
    ///   - outputFolder: Folder to save markdown transcript
    /// - Returns: URL of saved markdown file
    func transcribeMeetingFiles(micURL: URL, systemURL: URL?, outputFolder: URL) async throws -> URL {
        await MainActor.run {
            self.isProcessing = true
            self.error = nil
            self.processingStatus = "Starting transcription..."
        }

        let processingStartTime = Date()

        do {
            // Calculate recording duration from audio file
            let micFile = try AVAudioFile(forReading: micURL)
            let duration = Double(micFile.length) / micFile.processingFormat.sampleRate

            await MainActor.run {
                self.processingStatus = "Transcribing microphone..."
            }

            // Transcribe mic audio with timestamps
            let micSegments = try await transcribeAudioFileWithTimestamps(fileURL: micURL)

            var systemSegments: [TimestampedSegment] = []
            if let systemURL = systemURL {
                await MainActor.run {
                    self.processingStatus = "Transcribing system audio..."
                }
                systemSegments = try await transcribeAudioFileWithTimestamps(fileURL: systemURL)
            }

            await MainActor.run {
                self.processingStatus = "Merging transcripts..."
            }

            // Label sources
            let labeledMicSegments = micSegments.map {
                TimestampedSegment(timestamp: $0.timestamp, source: "Mic", text: $0.text)
            }
            let labeledSystemSegments = systemSegments.map {
                TimestampedSegment(timestamp: $0.timestamp, source: "System Audio", text: $0.text)
            }

            // Merge and sort by timestamp
            let allSegments = (labeledMicSegments + labeledSystemSegments).sorted { $0.timestamp < $1.timestamp }

            // Calculate processing time
            let processingTime = Date().timeIntervalSince(processingStartTime)

            await MainActor.run {
                self.processingStatus = "Saving transcript..."
            }

            // Save to markdown
            guard let fileURL = TranscriptSaver.save(
                segments: allSegments,
                duration: duration,
                processingTime: processingTime,
                directory: outputFolder
            ) else {
                throw NSError(domain: "Transcription", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to save transcript"
                ])
            }

            await MainActor.run {
                self.lastSavedFileURL = fileURL
                self.isProcessing = false
                self.processingStatus = "Complete!"
            }

            print("✅ Transcript saved: \(fileURL.lastPathComponent)")

            // Cleanup audio files after successful transcription
            cleanupAudioFiles(micURL: micURL, systemURL: systemURL)

            return fileURL

        } catch {
            await MainActor.run {
                self.error = "Transcription failed: \(error.localizedDescription)"
                self.isProcessing = false
                self.processingStatus = ""
            }
            throw error
        }
    }

    /// Transcribe audio file and extract timestamps per segment
    private func transcribeAudioFileWithTimestamps(fileURL: URL) async throws -> [TimestampedSegment] {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let fileFormat = audioFile.processingFormat

        print("📝 Transcribing: \(fileURL.lastPathComponent)")

        // Create transcriber with timestamp support
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],  // System uses best available
            reportingOptions: [],  // No volatile for file processing
            attributeOptions: [.audioTimeRange]  // Enable timing info
        )

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Query required format
        guard let requiredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "Transcription", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to get required audio format"
            ])
        }

        // Force Int16 format (transcriber requires it)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: requiredFormat.sampleRate,
            channels: requiredFormat.channelCount,
            interleaved: true
        ) else {
            throw NSError(domain: "Transcription", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create target format"
            ])
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        try await analyzer.start(inputSequence: inputSequence)

        // Collect results with timestamp extraction
        let resultTask = Task<[TimestampedSegment], Error> {
            var segments: [TimestampedSegment] = []

            for try await result in transcriber.results {
                if result.isFinal {
                    var wordSegments: [(timestamp: TimeInterval, text: String)] = []

                    // Extract timestamps from AttributedString runs
                    for run in result.text.runs {
                        if let timeRange = run.attributes.audioTimeRange {
                            let startTime = CMTimeGetSeconds(timeRange.start)
                            let text = String(result.text.characters[run.range])
                            wordSegments.append((timestamp: startTime, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                    }

                    if !wordSegments.isEmpty {
                        // Group words into sentences
                        let groupedSegments = self.groupWordsIntoSentences(wordSegments)
                        segments.append(contentsOf: groupedSegments)
                    } else {
                        // Fallback if no timing data
                        let fullText = String(result.text.characters)
                        if !fullText.isEmpty {
                            segments.append(TimestampedSegment(
                                timestamp: 0.0,
                                source: "",
                                text: fullText
                            ))
                        }
                    }
                }
            }

            return segments
        }

        // Process file in chunks (45-second chunks to avoid 60-second API limit)
        let chunkDurationSeconds = 45.0
        let chunkFrameCount = AVAudioFrameCount(fileFormat.sampleRate * chunkDurationSeconds)
        let totalFrames = AVAudioFrameCount(audioFile.length)

        // Create converter if format doesn't match
        var converter: AVAudioConverter? = nil
        if !(fileFormat.commonFormat == targetFormat.commonFormat &&
             fileFormat.sampleRate == targetFormat.sampleRate &&
             fileFormat.channelCount == targetFormat.channelCount) {
            guard let conv = AVAudioConverter(from: fileFormat, to: targetFormat) else {
                throw NSError(domain: "Transcription", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create audio converter"
                ])
            }
            conv.sampleRateConverterQuality = .max
            conv.dither = true
            converter = conv
        }

        var framesProcessed: AVAudioFrameCount = 0

        while framesProcessed < totalFrames {
            let framesToRead = min(chunkFrameCount, totalFrames - framesProcessed)

            guard let chunkBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: framesToRead) else {
                throw NSError(domain: "Transcription", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create buffer"
                ])
            }

            try audioFile.read(into: chunkBuffer, frameCount: framesToRead)

            let finalBuffer: AVAudioPCMBuffer
            if let converter = converter {
                // Convert chunk
                let ratio = targetFormat.sampleRate / fileFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(chunkBuffer.frameLength) * ratio) + 1

                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                    throw NSError(domain: "Transcription", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "Failed to create conversion buffer"
                    ])
                }

                var error: NSError?
                let inputBuffer = chunkBuffer // Capture to avoid Sendable warning
                let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return inputBuffer
                }

                if let error = error { throw error }
                if status == .error {
                    throw NSError(domain: "Transcription", code: 6, userInfo: [
                        NSLocalizedDescriptionKey: "Audio conversion failed"
                    ])
                }

                finalBuffer = convertedBuffer
            } else {
                finalBuffer = chunkBuffer
            }

            let input = AnalyzerInput(buffer: finalBuffer)
            inputBuilder.yield(input)

            framesProcessed += framesToRead
        }

        inputBuilder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let finalSegments = try await resultTask.value
        print("✓ Transcription complete: \(finalSegments.count) segments")

        return finalSegments
    }

    /// Group word-level timestamps into sentence-level segments
    private func groupWordsIntoSentences(_ words: [(timestamp: TimeInterval, text: String)]) -> [TimestampedSegment] {
        guard !words.isEmpty else { return [] }

        var sentences: [TimestampedSegment] = []
        var currentWords: [String] = []
        var sentenceStartTime: TimeInterval = words[0].timestamp

        let sentenceEnders: Set<Character> = [".", "!", "?"]
        let pauseThreshold: TimeInterval = 1.0  // 1 second pause indicates new sentence

        for (index, word) in words.enumerated() {
            currentWords.append(word.text)

            let endsWithPunctuation = word.text.last.map { sentenceEnders.contains($0) } ?? false
            let hasLongPauseAfter = index < words.count - 1 && (words[index + 1].timestamp - word.timestamp > pauseThreshold)
            let isLastWord = index == words.count - 1

            // End sentence if: punctuation, long pause, or last word
            if endsWithPunctuation || hasLongPauseAfter || isLastWord {
                let sentenceText = currentWords.joined(separator: " ")
                if !sentenceText.isEmpty {
                    sentences.append(TimestampedSegment(
                        timestamp: sentenceStartTime,
                        source: "",
                        text: sentenceText
                    ))
                }

                // Start new sentence
                currentWords = []
                if index < words.count - 1 {
                    sentenceStartTime = words[index + 1].timestamp
                }
            }
        }

        return sentences
    }

    /// Cleanup audio files after successful transcription
    private func cleanupAudioFiles(micURL: URL, systemURL: URL?) {
        // Delete mic audio file
        do {
            try FileManager.default.removeItem(at: micURL)
            print("🗑️ Deleted mic audio file: \(micURL.lastPathComponent)")
        } catch {
            print("⚠️ Failed to delete mic audio file: \(error.localizedDescription)")
        }

        // Delete system audio file if it exists
        if let systemURL = systemURL {
            do {
                try FileManager.default.removeItem(at: systemURL)
                print("🗑️ Deleted system audio file: \(systemURL.lastPathComponent)")
            } catch {
                print("⚠️ Failed to delete system audio file: \(error.localizedDescription)")
            }
        }
    }
}

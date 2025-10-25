import Foundation
import Speech
import AVFoundation

struct TimestampedSegment {
    let timestamp: TimeInterval
    let source: String  // "Mic" or "System Audio"
    let text: String
}

@available(macOS 26.0, *)
class Transcription: ObservableObject {
    @Published var currentText: String = ""
    @Published var isProcessing: Bool = false
    @Published var error: String?
    @Published var isProcessingSystemAudio: Bool = false
    @Published var systemAudioText: String = ""
    @Published var lastSavedFileURL: URL?  // Track last saved file for UI feedback
    @Published var usingOnDeviceMode: Bool = false  // Track which mode is active

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var recognizerTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var bufferConverter: BufferConverter?
    private var hasCopied: Bool = false
    private let monitor = AudioDebugMonitor.shared

    // Speech model manager for hybrid on-device/server approach
    var modelManager: SpeechModelManager?

    // Track accumulated final text separately from volatile
    private var accumulatedFinalText: String = ""

    // Track recording duration for auto-save
    private var recordingStartTime: Date?
    private var recordingDuration: TimeInterval = 0.0

    // Debug: Record audio being sent to transcriber
    private var audioFile: AVAudioFile?
    private var recordingEnabled = false  // DISABLED - causing freezing, will re-enable later
    private let fileWriteQueue = DispatchQueue(label: "TranscriptionFileWrite", qos: .utility)

    init() {
        // Transcription initialized
    }

    /// Get the audio format that SpeechAnalyzer expects
    /// Returns nil if transcription hasn't been started yet
    func getAnalyzerFormat() -> AVAudioFormat? {
        return analyzerFormat
    }

    func start() {
        Task {
            do {
                try await startAsync()
            } catch {
                await MainActor.run {
                    self.error = "Failed to start transcription: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }

    /// Starts transcription and waits for it to be fully initialized
    func startAndWait() async throws {
        try await startAsync()
    }

    private func startAsync() async throws {
        // Reset state
        await MainActor.run {
            self.currentText = ""
            self.error = nil
            self.hasCopied = false
        }

        accumulatedFinalText = ""
        recordingStartTime = Date()  // Track when recording started

        // Create transcriber optimized for continuous audio (mixed mic + system audio)
        // SpeechTranscriber (macOS 26.0+) has limited configuration options
        // The main tuning is done via reportingOptions and attributeOptions

        // For macOS 26.0, SpeechTranscriber always uses on-device when available
        // Empty transcriptionOptions [] means: use on-device if available, fallback to server if not
        // This is the intended behavior - the system handles the fallback automatically
        transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],  // System automatically uses best available option
            reportingOptions: [.volatileResults],  // Get progressive updates for real-time feedback
            attributeOptions: [.audioTimeRange]  // Track timing information
        )

        // Track which mode we're using based on model availability
        let useOnDevice = modelManager?.isOnDeviceAvailable ?? false
        await MainActor.run {
            self.usingOnDeviceMode = useOnDevice
        }

        monitor.log("Transcriber initialized (on-device model \(useOnDevice ? "available" : "not available"))", level: .info)

        // Create analyzer with transcriber module
        analyzer = SpeechAnalyzer(modules: [transcriber!])

        // Get best audio format compatible with transcriber
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber!]
        )

        guard let format = analyzerFormat else {
            throw NSError(domain: "Transcription", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to get audio format from SpeechAnalyzer"
            ])
        }

        // Create debug recording file (disabled for performance)
        if recordingEnabled {
            do {
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let audioURL = documentsPath.appendingPathComponent("transcriber_input_\(timestamp).wav")
                audioFile = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            } catch {
                audioFile = nil
            }
        }

        // Create buffer converter
        bufferConverter = BufferConverter(to: format)

        // Create input stream for feeding audio buffers
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder

        // Start task to listen for transcription results
        recognizerTask = Task { [weak self] in
            guard let self = self, let transcriber = self.transcriber else { return }

            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)

                    if result.isFinal {
                        // Accumulate final results
                        self.accumulatedFinalText += text

                        await MainActor.run {
                            self.currentText = self.accumulatedFinalText
                            self.error = nil
                            self.monitor.updateMixedTranscription(self.accumulatedFinalText)
                        }
                        self.monitor.log("Final segment added", level: .success)
                    } else {
                        // Show volatile results temporarily (accumulated finals + current volatile)
                        let displayText = self.accumulatedFinalText + text

                        await MainActor.run {
                            self.currentText = displayText
                            self.monitor.updateMixedTranscription(displayText)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = "Transcription error: \(error.localizedDescription)"
                }
            }
        }

        // Start the analyzer with the input sequence
        try await analyzer?.start(inputSequence: inputSequence)

        await MainActor.run {
            self.isProcessing = true
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Write to debug recording file on background queue (non-blocking)
        if let audioFile = audioFile, recordingEnabled {
            // Make a copy of the buffer for async writing
            if let bufferCopy = copyBuffer(buffer) {
                fileWriteQueue.async {
                    do {
                        try audioFile.write(from: bufferCopy)
                    } catch {
                        // Silently fail to avoid spam
                    }
                }
            }
        }

        // Check if buffer is already in the correct format
        if buffer.format == analyzerFormat {
            // Perfect! No conversion needed - AudioMixer already did the work
            let input = AnalyzerInput(buffer: buffer)
            inputBuilder?.yield(input)
            return
        }

        // Fallback: use BufferConverter if format doesn't match
        guard let converter = bufferConverter else {
            return
        }

        guard let convertedBuffer = converter.convert(buffer) else {
            return
        }

        // Send converted buffer to analyzer
        let input = AnalyzerInput(buffer: convertedBuffer)
        inputBuilder?.yield(input)
    }

    func stop() {
        // Calculate and store recording duration
        recordingDuration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0.0

        // Close debug audio file
        if let audioFile = audioFile {
            self.audioFile = nil
        }

        // Finish the input stream
        inputBuilder?.finish()

        // Finalize analyzer
        Task {
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                // Silently handle finalization errors
            }
        }

        // Cancel recognition task
        recognizerTask?.cancel()

        DispatchQueue.main.async {
            self.isProcessing = false
        }

        // NOTE: File saving happens in finalizeAndSave() after system audio is processed
    }

    /// Finalize transcript and save to file (called after system audio processing completes OR immediately if no system audio)
    func finalizeAndSave() {
        if !currentText.isEmpty {
            // Auto-save transcript to file
            if let fileURL = TranscriptSaver.save(text: currentText, duration: recordingDuration) {
                DispatchQueue.main.async {
                    self.lastSavedFileURL = fileURL
                }
            }
        }
    }

    func reset() {
        recognizerTask?.cancel()
        recognizerTask = nil
        inputBuilder?.finish()
        inputBuilder = nil
        transcriber = nil
        analyzer = nil
        bufferConverter = nil
        accumulatedFinalText = ""
        audioFile = nil
        recordingStartTime = nil

        DispatchQueue.main.async {
            self.currentText = ""
            self.isProcessing = false
            self.error = nil
            self.hasCopied = false
        }
    }

    /// Prepare for next recording session
    /// Lighter reset that clears session data while preserving configuration
    func resetForNextRecording() {
        // Clean up any lingering transcription resources
        recognizerTask?.cancel()
        recognizerTask = nil
        inputBuilder?.finish()
        inputBuilder = nil
        transcriber = nil
        analyzer = nil
        bufferConverter = nil
        accumulatedFinalText = ""
        audioFile = nil
        recordingStartTime = nil

        // Clear UI state on main thread
        DispatchQueue.main.async {
            self.error = nil
            self.isProcessing = false
            self.isProcessingSystemAudio = false
            // Keep currentText and lastSavedFileURL so user can still access previous transcript
        }
    }

    /// Copy a buffer for async processing
    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }

        copy.frameLength = buffer.frameLength

        // Copy audio data based on format
        if let srcInt16 = buffer.int16ChannelData, let dstInt16 = copy.int16ChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(dstInt16[channel], srcInt16[channel], Int(buffer.frameLength) * MemoryLayout<Int16>.size)
            }
        } else if let srcFloat = buffer.floatChannelData, let dstFloat = copy.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(dstFloat[channel], srcFloat[channel], Int(buffer.frameLength) * MemoryLayout<Float>.size)
            }
        } else if let srcInt32 = buffer.int32ChannelData, let dstInt32 = copy.int32ChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(dstInt32[channel], srcInt32[channel], Int(buffer.frameLength) * MemoryLayout<Int32>.size)
            }
        }

        return copy
    }

    /// Transcribe both mic and system audio files in parallel for maximum speed
    /// Returns merged transcript with both streams in timeline format
    func transcribeBothFiles(micURL: URL, systemURL: URL?, recordingDuration: TimeInterval, processingStartTime: Date) async throws {
        await MainActor.run {
            self.isProcessing = true
            self.currentText = ""
            self.error = nil
        }

        do {
            // Transcribe both files in parallel with timestamps
            async let micSegmentsTask = transcribeAudioFileWithTimestamps(fileURL: micURL)

            var systemSegments: [TimestampedSegment] = []
            if let systemURL = systemURL {
                async let systemSegmentsTask = transcribeAudioFileWithTimestamps(fileURL: systemURL)
                systemSegments = try await systemSegmentsTask
            }

            var micSegments = try await micSegmentsTask

            // Label sources
            micSegments = micSegments.map {
                TimestampedSegment(timestamp: $0.timestamp, source: "Mic", text: $0.text)
            }
            systemSegments = systemSegments.map {
                TimestampedSegment(timestamp: $0.timestamp, source: "System Audio", text: $0.text)
            }

            // Merge and sort by timestamp
            let allSegments = (micSegments + systemSegments).sorted { $0.timestamp < $1.timestamp }

            // Build text for UI display (inline format like the saved file)
            let displayText = allSegments.map { segment in
                let timestamp = self.formatTimeInterval(segment.timestamp)
                let sourceLabel = segment.source == "System Audio" ? "SysAudio" : segment.source
                return "[\(timestamp)] [\(sourceLabel)] \(segment.text)"
            }.joined(separator: "\n")

            await MainActor.run {
                self.currentText = displayText
                self.isProcessing = false
                self.recordingDuration = recordingDuration
            }

            // Calculate processing time (from stop button to transcript ready)
            let processingTime = Date().timeIntervalSince(processingStartTime)

            // Save transcript with timeline format
            if let fileURL = TranscriptSaver.save(segments: allSegments, duration: recordingDuration, processingTime: processingTime) {
                await MainActor.run {
                    self.lastSavedFileURL = fileURL
                }
            }

            // Keep audio files for testing - don't delete them
            // try? FileManager.default.removeItem(at: micURL)
            // if let systemURL = systemURL {
            //     try? FileManager.default.removeItem(at: systemURL)
            // }

        } catch {
            await MainActor.run {
                self.error = "Transcription failed: \(error.localizedDescription)"
                self.isProcessing = false
            }
            throw error
        }
    }

    /// Merge microphone and system audio transcripts with clear separation
    private func mergeTranscripts(mic: String, system: String) -> String {
        if mic.isEmpty && system.isEmpty {
            return "*No speech detected*"
        }

        if mic.isEmpty {
            return "## System Audio\n\n\(system)"
        }

        if system.isEmpty {
            return "## Microphone\n\n\(mic)"
        }

        // Both present - show both with clear sections
        return """
        ## Microphone

        \(mic)

        ## System Audio

        \(system)
        """
    }

    /// Fast post-processing transcription using SpeechAnalyzer for on-device processing
    /// This method processes entire audio files quickly (~2.2x faster than cloud APIs)
    /// Audio files MUST already be in optimal format (queried from SpeechAnalyzer at startup)
    func transcribeAudioFile(fileURL: URL) async throws -> String {
        // Read the audio file
        let audioFile = try AVAudioFile(forReading: fileURL)
        let fileFormat = audioFile.processingFormat

        monitor.log("Transcribing file: \(fileURL.lastPathComponent) - format: \(fileFormat.sampleRate)Hz \(fileFormat.channelCount)ch \(fileFormat.commonFormat.rawValue)", level: .info)

        // Create transcriber optimized for file processing
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],  // System uses best available (on-device or server)
            reportingOptions: [],  // No volatileResults for faster file processing
            attributeOptions: []  // Minimal attributes for speed
        )

        // Create analyzer with transcriber module
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Query the format that SpeechAnalyzer expects
        guard let requiredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "Transcription", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to get required audio format from SpeechAnalyzer"
            ])
        }

        // CRITICAL: Force Int16 format (SpeechAnalyzer may return Float32 but transcriber requires Int16)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: requiredFormat.sampleRate,
            channels: requiredFormat.channelCount,
            interleaved: true
        ) else {
            throw NSError(domain: "Transcription", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create Int16 target format"
            ])
        }

        monitor.log("Target format: \(targetFormat.sampleRate)Hz \(targetFormat.channelCount)ch Int16", level: .info)

        // Create input stream for file processing
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        // Start analyzer
        try await analyzer.start(inputSequence: inputSequence)

        // Create task to collect results
        let resultTask = Task<String, Error> {
            var text = ""
            for try await result in transcriber.results {
                if result.isFinal {
                    text += String(result.text.characters)
                }
            }
            return text
        }

        // Process file in 45-second chunks to avoid 60-second limit
        let chunkDurationSeconds = 45.0
        let chunkFrameCount = AVAudioFrameCount(fileFormat.sampleRate * chunkDurationSeconds)
        let totalFrames = AVAudioFrameCount(audioFile.length)

        monitor.log("Processing audio: \(totalFrames) total frames, \(chunkFrameCount) frames per chunk", level: .info)

        // Create converter once outside loop (if needed)
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
            monitor.log("Created audio converter: \(fileFormat.sampleRate)Hz → \(targetFormat.sampleRate)Hz", level: .info)
        } else {
            monitor.log("No conversion needed, formats match", level: .info)
        }

        // Process file in chunks
        var framesProcessed: AVAudioFrameCount = 0
        var chunkIndex = 0

        while framesProcessed < totalFrames {
            chunkIndex += 1
            let framesToRead = min(chunkFrameCount, totalFrames - framesProcessed)

            // Read chunk from file
            guard let chunkBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: framesToRead) else {
                throw NSError(domain: "Transcription", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create buffer for chunk \(chunkIndex)"
                ])
            }

            try audioFile.read(into: chunkBuffer, frameCount: framesToRead)

            // Convert chunk if needed
            let finalBuffer: AVAudioPCMBuffer
            if let converter = converter {
                // Convert this chunk
                let ratio = targetFormat.sampleRate / fileFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(chunkBuffer.frameLength) * ratio) + 1

                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                    throw NSError(domain: "Transcription", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "Failed to create conversion buffer for chunk \(chunkIndex)"
                    ])
                }

                var error: NSError?
                let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return chunkBuffer
                }

                if let error = error {
                    throw error
                }

                if status == .error {
                    throw NSError(domain: "Transcription", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "Audio conversion failed for chunk \(chunkIndex)"
                    ])
                }

                finalBuffer = convertedBuffer
                monitor.log("Chunk \(chunkIndex): converted \(chunkBuffer.frameLength) → \(convertedBuffer.frameLength) frames", level: .info)
            } else {
                // No conversion needed
                finalBuffer = chunkBuffer
                monitor.log("Chunk \(chunkIndex): using \(chunkBuffer.frameLength) frames directly", level: .info)
            }

            // Send chunk to analyzer
            let input = AnalyzerInput(buffer: finalBuffer)
            inputBuilder.yield(input)

            framesProcessed += framesToRead
        }

        monitor.log("All \(chunkIndex) chunks sent to transcriber (\(framesProcessed) total frames)", level: .success)

        // Finish input and finalize
        inputBuilder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        // Wait for results
        let finalTranscript = try await resultTask.value

        monitor.log("Transcription complete: \(finalTranscript.count) characters", level: .success)

        return finalTranscript
    }

    /// Transcribe audio file and extract timestamps per segment using AttributedString runs
    func transcribeAudioFileWithTimestamps(fileURL: URL) async throws -> [TimestampedSegment] {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let fileFormat = audioFile.processingFormat

        monitor.log("Transcribing with timestamps: \(fileURL.lastPathComponent)", level: .info)

        // Create transcriber WITH audioTimeRange attribute
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],  // System uses best available (on-device or server)
            reportingOptions: [],  // No volatile for faster file processing
            attributeOptions: [.audioTimeRange]  // KEY: Enable timing info
        )

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let requiredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "Transcription", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to get required audio format"
            ])
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: requiredFormat.sampleRate,
            channels: requiredFormat.channelCount,
            interleaved: true
        ) else {
            throw NSError(domain: "Transcription", code: 1, userInfo: [
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
                    // EXPERIMENT: Try to extract timestamps from AttributedString runs
                    var extractedFromRuns = false
                    var wordSegments: [(timestamp: TimeInterval, text: String)] = []

                    // Iterate through runs in the AttributedString
                    for run in result.text.runs {
                        // Try different patterns to access audioTimeRange attribute
                        let attributes = run.attributes

                        // The audioTimeRange should be a CMTimeRange type
                        if let timeRange = attributes.audioTimeRange {
                            extractedFromRuns = true

                            let startTime = CMTimeGetSeconds(timeRange.start)
                            let text = String(result.text.characters[run.range])

                            wordSegments.append((timestamp: startTime, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                    }

                    if extractedFromRuns {
                        // Group words into sentences
                        let groupedSegments = self.groupWordsIntoSentences(wordSegments)
                        segments.append(contentsOf: groupedSegments)
                        self.monitor.log("Extracted \(groupedSegments.count) sentences from \(wordSegments.count) words", level: .info)
                    } else {
                        // FALLBACK: If no runs with timestamps, log and use whole result
                        let fullText = String(result.text.characters)
                        self.monitor.log("⚠️ No audioTimeRange in runs, using full result", level: .warning)

                        // Add single segment (will estimate timing later)
                        segments.append(TimestampedSegment(
                            timestamp: 0.0,
                            source: "",
                            text: fullText
                        ))
                    }
                }
            }

            return segments
        }

        // Process file in chunks (same as existing implementation)
        let chunkDurationSeconds = 45.0
        let chunkFrameCount = AVAudioFrameCount(fileFormat.sampleRate * chunkDurationSeconds)
        let totalFrames = AVAudioFrameCount(audioFile.length)

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
                throw NSError(domain: "Transcription", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create buffer"
                ])
            }

            try audioFile.read(into: chunkBuffer, frameCount: framesToRead)

            let finalBuffer: AVAudioPCMBuffer
            if let converter = converter {
                let ratio = targetFormat.sampleRate / fileFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(chunkBuffer.frameLength) * ratio) + 1

                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                    throw NSError(domain: "Transcription", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "Failed to create conversion buffer"
                    ])
                }

                var error: NSError?
                let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return chunkBuffer
                }

                if let error = error { throw error }
                if status == .error {
                    throw NSError(domain: "Transcription", code: 5, userInfo: [
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
        monitor.log("Transcription complete: \(finalSegments.count) segments extracted", level: .success)

        return finalSegments
    }

    /// Format TimeInterval as MM:SS for display
    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Group word-level timestamps into sentence-level segments
    /// Uses punctuation and pauses to detect sentence boundaries
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

    /// Process system audio file after recording stops (post-processing transcription)
    func processSystemAudio(fileURL: URL) async {
        await MainActor.run {
            self.isProcessingSystemAudio = true
            self.systemAudioText = ""
        }

        do {
            // Read the audio file
            let audioFile = try AVAudioFile(forReading: fileURL)
            let format = audioFile.processingFormat

            // Create speech recognizer for file-based transcription
            let recognizer = SFSpeechRecognizer(locale: Locale.current)
            guard let recognizer = recognizer else {
                throw NSError(domain: "Transcription", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Speech recognizer not available"
                ])
            }

            guard recognizer.isAvailable else {
                throw NSError(domain: "Transcription", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Speech recognizer not available"
                ])
            }

            // Create recognition request with audio file
            let request = SFSpeechURLRecognitionRequest(url: fileURL)
            request.shouldReportPartialResults = false
            request.requiresOnDeviceRecognition = false

            // Perform recognition using continuation-based async
            let transcribedText = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                var hasResumed = false

                recognizer.recognitionTask(with: request) { result, error in
                    guard !hasResumed else { return }

                    if let error = error {
                        hasResumed = true
                        continuation.resume(throwing: error)
                        return
                    }

                    if let result = result, result.isFinal {
                        hasResumed = true
                        let text = result.bestTranscription.formattedString
                        continuation.resume(returning: text)
                    }
                }
            }

            await MainActor.run {
                self.systemAudioText = transcribedText
                self.isProcessingSystemAudio = false

                // Merge with mic transcription (append system audio after mic text)
                if !transcribedText.isEmpty {
                    if !self.currentText.isEmpty {
                        self.currentText += "\n\n--- System Audio ---\n" + transcribedText
                    } else {
                        self.currentText = transcribedText
                    }
                }
            }

            // Clean up the audio file after successful transcription
            try? FileManager.default.removeItem(at: fileURL)

        } catch {
            await MainActor.run {
                self.error = "System audio transcription failed: \(error.localizedDescription)"
                self.isProcessingSystemAudio = false
            }
        }

        // Auto-save transcript NOW that system audio has been merged
        await MainActor.run {
            self.finalizeAndSave()
        }
    }
}

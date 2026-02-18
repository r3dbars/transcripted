// SpeechEngine.swift
// Continuous speech recognition with silence-based commitment and buffer reset detection

import SwiftUI
import Speech
import AVFoundation

@MainActor
class SpeechEngine: ObservableObject {
    @Published var finalTranscript = ""    // Append-only: confirmed text
    @Published var volatileText = ""       // Replace-only: current unfinalized speech
    @Published var isListening = false
    @Published var statusMessage = "Tap Record to start"
    @Published var speechFinished = false  // True after extended silence (2.5s) — signals "done talking"

    var displayText: String { finalTranscript + volatileText }
    var hasText: Bool { !finalTranscript.isEmpty || !volatileText.isEmpty }

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    // Silence detection — commits volatile text when user pauses
    private var silenceTimer: Timer?
    private let silenceThreshold: TimeInterval = 1.5
    private var lastVolatileSnapshot = ""

    // "Done speaking" detection — longer silence signals user is finished
    private var doneTimer: Timer?
    private let doneThreshold: TimeInterval = 2.5

    // Tracks how much of the current task's cumulative text we've already committed
    private var committedPrefixLength = 0
    private var committedPrefixContent = ""   // The actual text content at commit time — for content shift detection
    private var lastSeenFullText = ""         // Most recent fullText from Apple (for commit reference)
    private var callbackCount = 0
    private var taskGeneration = 0

    private func log(_ msg: String) {
        let entry = "[\(taskGeneration).\(callbackCount)] \(msg)"
        print(entry)
        // Also write to debug log file so we can diagnose issues
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] SPEECH \(msg)\n"
        let logPath = FileManager.default.homeDirectoryForCurrentUser.path + "/draft-debug.log"
        if let data = logLine.data(using: .utf8), let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        }
    }

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func requestPermissions() async -> Bool {
        log("🎤 PERM CHECK | starting permission requests...")

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        log("🎤 PERM CHECK | speechStatus=\(speechStatus.rawValue) (0=notDetermined, 1=denied, 2=restricted, 3=authorized)")

        guard speechStatus == .authorized else {
            log("❌ PERM | speech recognition NOT authorized (status=\(speechStatus.rawValue))")
            statusMessage = "Speech recognition not authorized"
            return false
        }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        log("🎤 PERM CHECK | micStatus=\(micStatus.rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")

        if micStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            log("🎤 PERM CHECK | mic access request result=\(granted)")
            if !granted {
                log("❌ PERM | microphone access denied")
                statusMessage = "Microphone access denied"
                return false
            }
        } else if micStatus != .authorized {
            log("❌ PERM | microphone not authorized (status=\(micStatus.rawValue))")
            statusMessage = "Microphone access denied"
            return false
        }

        let recognizerAvailable = speechRecognizer?.isAvailable ?? false
        log("✅ PERM | all granted. recognizerAvailable=\(recognizerAvailable)")
        statusMessage = "Ready — tap Record"
        return true
    }

    // MARK: - Public Controls

    func startListening() {
        if speechRecognizer == nil {
            log("❌ SPEECH | recognizer is nil")
            statusMessage = "Speech recognizer not available"
            return
        }
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            log("❌ SPEECH | recognizer not available (isAvailable=false)")
            statusMessage = "Speech recognizer not available"
            return
        }
        guard !isListening else {
            log("⚠️ SPEECH | already listening, ignoring startListening()")
            return
        }

        speechRecognizer.defaultTaskHint = .dictation

        committedPrefixLength = 0
        committedPrefixContent = ""
        lastSeenFullText = ""
        callbackCount = 0
        taskGeneration = 0
        silenceTimer?.invalidate()
        doneTimer?.invalidate()
        lastVolatileSnapshot = ""
        speechFinished = false

        log("▶️ START LISTENING")

        createRecognitionTask()

        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        log("🎤 AUDIO FORMAT native | sampleRate=\(nativeFormat.sampleRate) channels=\(nativeFormat.channelCount)")

        // Force mono at the hardware's native sample rate. Multi-channel pro audio interfaces
        // (e.g., BEACN Mic at 96kHz/4ch) cause SFSpeechRecognizer error 1110 "no speech detected."
        // AVAudioEngine handles the channel mixdown automatically on the tap.
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: nativeFormat.sampleRate, channels: 1)!
        log("🎤 AUDIO FORMAT tap | sampleRate=\(monoFormat.sampleRate) channels=\(monoFormat.channelCount)")

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: monoFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            log("🎤 AUDIO ENGINE STARTED")
        } catch {
            log("❌ AUDIO ENGINE FAILED | \(error.localizedDescription)")
            statusMessage = "Audio engine failed: \(error.localizedDescription)"
        }
    }

    func stopListening() {
        log("⏹️ STOP | volatile=\"\(volatileText)\" | final=\"\(finalTranscript.suffix(60))\"")

        silenceTimer?.invalidate()
        silenceTimer = nil
        doneTimer?.invalidate()
        doneTimer = nil

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false

        if !volatileText.isEmpty {
            finalTranscript += volatileText + "\n"
            volatileText = ""
        }

        committedPrefixLength = 0
        committedPrefixContent = ""
        lastSeenFullText = ""
        lastVolatileSnapshot = ""
        statusMessage = "Ready — tap Record"
    }

    func clear() {
        finalTranscript = ""
        volatileText = ""
        speechFinished = false
        committedPrefixLength = 0
        committedPrefixContent = ""
        lastSeenFullText = ""
    }

    // MARK: - Recognition Task Management

    private func createRecognitionTask() {
        guard let speechRecognizer = speechRecognizer else { return }

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        let onDevice = speechRecognizer.supportsOnDeviceRecognition
        if onDevice {
            newRequest.requiresOnDeviceRecognition = true
            statusMessage = "🟢 Listening (on-device)"
        } else {
            newRequest.requiresOnDeviceRecognition = false
            statusMessage = "🟢 Listening (server)"
        }
        recognitionRequest = newRequest

        log("📡 TASK CREATED (gen \(taskGeneration), onDevice=\(onDevice))")

        recognitionTask = speechRecognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            self?.handleRecognitionResult(result, error: error)
        }
    }

    private func restartRecognitionTask() {
        guard isListening else {
            log("⚠️ RESTART skipped — not listening")
            return
        }
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            log("⚠️ RESTART skipped — recognizer unavailable")
            return
        }

        taskGeneration += 1
        callbackCount = 0
        log("🔄 RESTART TASK → gen \(taskGeneration)")

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        committedPrefixLength = 0
        committedPrefixContent = ""
        lastSeenFullText = ""
        silenceTimer?.invalidate()
        lastVolatileSnapshot = ""

        createRecognitionTask()
    }

    // MARK: - Recognition Callback

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result = result {
            Task { @MainActor in
                self.callbackCount += 1
                let fullText = result.bestTranscription.formattedString

                if result.isFinal {
                    self.log("🏁 isFinal | fullText(\(fullText.count))")
                    self.commitRemainingText(from: fullText)
                    self.restartRecognitionTask()
                } else {
                    // Detect Apple Speech buffer reset or content revision
                    if fullText.count < self.committedPrefixLength {
                        // Buffer completely reset — fullText is shorter than our committed prefix
                        self.log("🔀 BUFFER RESET | full(\(fullText.count)) < prefix(\(self.committedPrefixLength)) → reset to 0")
                        self.committedPrefixLength = 0
                        self.committedPrefixContent = ""
                    } else if !self.committedPrefixContent.isEmpty && !fullText.hasPrefix(self.committedPrefixContent) {
                        // Content shift — Apple revised text we already committed.
                        // Find how many characters from the start still match, then realign.
                        let commonLen = zip(fullText, self.committedPrefixContent).prefix(while: { $0 == $1 }).count
                        self.log("🔀 CONTENT SHIFT | prefix was \(self.committedPrefixLength) → realigned to \(commonLen) (committed \"\(self.committedPrefixContent.prefix(30))\" vs full \"\(fullText.prefix(30))\")")
                        self.committedPrefixLength = commonLen
                        self.committedPrefixContent = String(fullText.prefix(commonLen))
                    }

                    self.lastSeenFullText = fullText

                    let extracted: String
                    if self.committedPrefixLength < fullText.count {
                        let startIndex = fullText.index(fullText.startIndex, offsetBy: self.committedPrefixLength)
                        extracted = String(fullText[startIndex...]).trimmingCharacters(in: .whitespaces)
                    } else {
                        extracted = ""
                    }
                    self.volatileText = extracted
                    self.resetSilenceTimer()
                }
            }
        }

        if let error = error {
            Task { @MainActor in
                let nsError = error as NSError
                self.log("❌ ERROR code=\(nsError.code) | \(error.localizedDescription)")

                if nsError.code == 203 || nsError.code == 216 {
                    if !self.volatileText.isEmpty {
                        self.finalTranscript += self.volatileText + " "
                        self.volatileText = ""
                    }
                    self.restartRecognitionTask()
                } else {
                    self.statusMessage = "Error: \(error.localizedDescription)"
                    self.stopListening()
                }
            }
        }
    }

    // MARK: - Silence Detection

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        lastVolatileSnapshot = volatileText

        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.commitVolatileOnSilence()
            }
        }

        // Also reset the "done speaking" timer — longer threshold
        resetDoneTimer()
    }

    private func resetDoneTimer() {
        doneTimer?.invalidate()
        speechFinished = false

        doneTimer = Timer.scheduledTimer(withTimeInterval: doneThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isListening, self.hasText else { return }
                self.log("🏁 DONE TIMER | speech finished after \(self.doneThreshold)s silence")
                self.speechFinished = true
            }
        }
    }

    private func commitVolatileOnSilence() {
        guard !volatileText.isEmpty, volatileText == lastVolatileSnapshot else { return }

        log("⏱️ SILENCE COMMIT | volatile=\"\(volatileText.prefix(40))...\"")

        finalTranscript += volatileText + "\n"
        committedPrefixLength = lastSeenFullText.count
        committedPrefixContent = lastSeenFullText
        volatileText = ""
        lastVolatileSnapshot = ""
    }

    private func commitRemainingText(from fullText: String) {
        // On isFinal, verify prefix alignment before extracting remaining text
        let effectivePrefix: Int
        if !committedPrefixContent.isEmpty && !fullText.hasPrefix(committedPrefixContent) {
            let commonLen = zip(fullText, committedPrefixContent).prefix(while: { $0 == $1 }).count
            log("🔀 CONTENT SHIFT (isFinal) | prefix was \(committedPrefixLength) → \(commonLen)")
            effectivePrefix = commonLen
        } else {
            effectivePrefix = committedPrefixLength
        }

        let uncommitted: String
        if effectivePrefix < fullText.count {
            let startIndex = fullText.index(fullText.startIndex, offsetBy: effectivePrefix)
            uncommitted = String(fullText[startIndex...]).trimmingCharacters(in: .whitespaces)
        } else {
            uncommitted = volatileText
        }

        if !uncommitted.isEmpty {
            finalTranscript += uncommitted + " "
        }
        volatileText = ""
        silenceTimer?.invalidate()
    }
}

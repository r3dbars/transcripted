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
    private var lastSeenFullTextLength = 0
    private var callbackCount = 0
    private var taskGeneration = 0

    private func log(_ msg: String) {
        let entry = "[\(taskGeneration).\(callbackCount)] \(msg)"
        print(entry)
    }

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            statusMessage = "Speech recognition not authorized"
            return false
        }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                statusMessage = "Microphone access denied"
                return false
            }
        } else if micStatus != .authorized {
            statusMessage = "Microphone access denied"
            return false
        }

        statusMessage = "Ready — tap Record"
        return true
    }

    // MARK: - Public Controls

    func startListening() {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            statusMessage = "Speech recognizer not available"
            return
        }
        guard !isListening else { return }

        speechRecognizer.defaultTaskHint = .dictation

        committedPrefixLength = 0
        lastSeenFullTextLength = 0
        callbackCount = 0
        taskGeneration = 0
        silenceTimer?.invalidate()
        doneTimer?.invalidate()
        lastVolatileSnapshot = ""
        speechFinished = false

        log("▶️ START LISTENING")

        createRecognitionTask()

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
        } catch {
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
        lastSeenFullTextLength = 0
        lastVolatileSnapshot = ""
        statusMessage = "Ready — tap Record"
    }

    func clear() {
        finalTranscript = ""
        volatileText = ""
        speechFinished = false
        committedPrefixLength = 0
        lastSeenFullTextLength = 0
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
        lastSeenFullTextLength = 0
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
                    // Detect Apple Speech buffer reset — fullText shrunk below our prefix
                    if fullText.count < self.committedPrefixLength {
                        self.log("🔀 BUFFER RESET | full(\(fullText.count)) < prefix(\(self.committedPrefixLength)) → reset to 0")
                        self.committedPrefixLength = 0
                    }

                    self.lastSeenFullTextLength = fullText.count

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
        committedPrefixLength = lastSeenFullTextLength
        volatileText = ""
        lastVolatileSnapshot = ""
    }

    private func commitRemainingText(from fullText: String) {
        let uncommitted: String
        if committedPrefixLength < fullText.count {
            let startIndex = fullText.index(fullText.startIndex, offsetBy: committedPrefixLength)
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

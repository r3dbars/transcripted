// DraftApp.swift
// Minimal mic → text proof of concept using Apple Speech Framework

import SwiftUI
import Speech
import AVFoundation

// MARK: - Speech Engine

@MainActor
class SpeechEngine: ObservableObject {
    @Published var finalTranscript = ""    // Append-only: confirmed text
    @Published var volatileText = ""       // Replace-only: current unfinalized speech
    @Published var isListening = false
    @Published var statusMessage = "Tap Record to start"
    @Published var debugLog: [String] = [] // On-screen debug log

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

    // Tracks how much of the current task's cumulative text we've already committed
    private var committedPrefixLength = 0
    private var lastSeenFullTextLength = 0  // Actual length from Apple Speech's buffer
    private var callbackCount = 0           // How many callbacks we've received
    private var taskGeneration = 0          // Which recognition task we're on

    private let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Draft/debug.log")

    private func log(_ msg: String) {
        let entry = "[\(taskGeneration).\(callbackCount)] \(msg)"
        print(entry)  // Console
        debugLog.append(entry)
        if debugLog.count > 50 { debugLog.removeFirst() }

        // Also write to file so we can inspect later
        let line = "\(Date()) \(entry)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
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

        // Configure for dictation (better continuous speech behavior)
        speechRecognizer.defaultTaskHint = .dictation

        // Reset per-session state
        committedPrefixLength = 0
        lastSeenFullTextLength = 0
        callbackCount = 0
        taskGeneration = 0
        silenceTimer?.invalidate()
        lastVolatileSnapshot = ""

        log("▶️ START LISTENING")

        // Create and start recognition task
        createRecognitionTask()

        // Setup audio engine
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

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false

        // Commit any remaining volatile text
        if !volatileText.isEmpty {
            log("⏹️ STOP committing volatile=\"\(volatileText)\"")
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
        log("🔄 RESTART TASK → gen \(taskGeneration) | final so far: \"\(finalTranscript.suffix(60))\"")

        // Tear down old task only (audio engine stays running)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        // Reset per-task tracking
        committedPrefixLength = 0
        lastSeenFullTextLength = 0
        silenceTimer?.invalidate()
        lastVolatileSnapshot = ""

        // Create fresh task — the audio tap automatically feeds the new request
        createRecognitionTask()
    }

    // MARK: - Recognition Callback

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result = result {
            Task { @MainActor in
                self.callbackCount += 1
                let fullText = result.bestTranscription.formattedString
                let segCount = result.bestTranscription.segments.count

                if result.isFinal {
                    self.log("🏁 isFinal | fullText(\(fullText.count))=\"\(fullText)\" | prefix=\(self.committedPrefixLength)")
                    self.commitRemainingText(from: fullText)
                    self.restartRecognitionTask()
                } else {
                    // Detect Apple Speech buffer reset — fullText shrunk below our prefix
                    if fullText.count < self.committedPrefixLength {
                        self.log("🔀 BUFFER RESET | full(\(fullText.count)) < prefix(\(self.committedPrefixLength)) → reset to 0")
                        self.committedPrefixLength = 0
                    }

                    self.lastSeenFullTextLength = fullText.count

                    // Extract only the portion we haven't committed yet
                    let extracted: String
                    if self.committedPrefixLength < fullText.count {
                        let startIndex = fullText.index(fullText.startIndex, offsetBy: self.committedPrefixLength)
                        extracted = String(fullText[startIndex...]).trimmingCharacters(in: .whitespaces)
                    } else {
                        extracted = ""
                    }
                    self.volatileText = extracted

                    self.log("📝 PARTIAL | full(\(fullText.count))=\"\(fullText)\" | prefix=\(self.committedPrefixLength) | volatile=\"\(extracted)\" | segs=\(segCount)")
                    self.resetSilenceTimer()
                }
            }
        }

        if let error = error {
            Task { @MainActor in
                let nsError = error as NSError
                self.log("❌ ERROR code=\(nsError.code) | \(error.localizedDescription)")

                if nsError.code == 203 || nsError.code == 216 {
                    self.log("🔄 Timeout restart | committing volatile=\"\(self.volatileText)\"")
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
    }

    private func commitVolatileOnSilence() {
        guard !volatileText.isEmpty, volatileText == lastVolatileSnapshot else {
            log("⏱️ SILENCE timer fired — skipped (empty=\(volatileText.isEmpty), changed=\(volatileText != lastVolatileSnapshot))")
            return
        }

        log("⏱️ SILENCE COMMIT | volatile=\"\(volatileText)\" | prefixWas=\(committedPrefixLength) → prefixNow=\(lastSeenFullTextLength)")

        // Move volatile text to final transcript
        finalTranscript += volatileText + "\n"

        // Use the actual buffer length from Apple Speech — no guessing
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

        log("🏁 COMMIT REMAINING | uncommitted=\"\(uncommitted)\" | prefix=\(committedPrefixLength) | fullLen=\(fullText.count)")

        if !uncommitted.isEmpty {
            finalTranscript += uncommitted + " "
        }
        volatileText = ""
        silenceTimer?.invalidate()
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var engine = SpeechEngine()

    var body: some View {
        VStack(spacing: 16) {
            // Header
            Text("Draft — Voice to Text")
                .font(.title2)
                .fontWeight(.semibold)

            Text(engine.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)

            // Transcript display
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !engine.finalTranscript.isEmpty {
                        Text(engine.finalTranscript)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !engine.volatileText.isEmpty {
                        Text(engine.volatileText)
                            .font(.body)
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if engine.isListening && engine.volatileText.isEmpty && engine.finalTranscript.isEmpty {
                        Text("Listening...")
                            .font(.body)
                            .foregroundColor(.blue.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !engine.hasText {
                        Text("Your speech will appear here...")
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )

            // Controls
            HStack(spacing: 12) {
                // Record / Stop button
                Button(action: {
                    if engine.isListening {
                        engine.stopListening()
                    } else {
                        engine.startListening()
                    }
                }) {
                    HStack {
                        Image(systemName: engine.isListening ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.title2)
                        Text(engine.isListening ? "Stop" : "Record")
                            .fontWeight(.medium)
                    }
                    .frame(minWidth: 120)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isListening ? .red : .blue)
                .keyboardShortcut(.space, modifiers: [])

                // Copy button
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(engine.displayText, forType: .string)
                    engine.statusMessage = "✅ Copied to clipboard!"
                }) {
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.bordered)
                .disabled(!engine.hasText)
                .keyboardShortcut("c", modifiers: .command)

                // Clear button
                Button(action: {
                    engine.clear()
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("Clear")
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.bordered)
                .disabled(!engine.hasText)
            }

            // Debug log panel
            DisclosureGroup("🔍 Debug Log (\(engine.debugLog.count) entries)") {
                ScrollView {
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(engine.debugLog.enumerated()), id: \.offset) { idx, entry in
                                Text(entry)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                        .onChange(of: engine.debugLog.count) {
                            if let last = engine.debugLog.indices.last {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
                .frame(height: 150)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(4)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 600)
        .task {
            await engine.requestPermissions()
        }
    }
}

// MARK: - App Entry

@main
struct DraftApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 550, height: 450)
    }
}

// STTRouter.swift
// Dual-engine STT router — holds WhisperEngine (always) + ParakeetEngine (optional),
// routes all calls to the active engine based on UserDefaults setting.
// Combines @Published properties from the active engine via Combine subscriptions.

import Combine
import SwiftUI

enum STTEngineChoice: String, CaseIterable {
    case whisper
    case parakeet
}

@MainActor
class STTRouter: ObservableObject {
    let whisperEngine = WhisperEngine()

    #if PARAKEET_AVAILABLE
    let parakeetEngine = ParakeetEngine()
    #endif

    @Published var activeChoice: STTEngineChoice

    // Forwarded from active engine
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var audioLevel: Float = 0
    @Published var liveTranscript: String = ""

    private var cancellables = Set<AnyCancellable>()

    var isModelLoaded: Bool {
        switch activeChoice {
        case .whisper:
            return whisperEngine.isModelLoaded
        case .parakeet:
            #if PARAKEET_AVAILABLE
            return parakeetEngine.isModelLoaded
            #else
            return false
            #endif
        }
    }

    var inputDeviceName: String {
        switch activeChoice {
        case .whisper:
            return whisperEngine.inputDeviceName
        case .parakeet:
            #if PARAKEET_AVAILABLE
            return parakeetEngine.inputDeviceName
            #else
            return "unknown"
            #endif
        }
    }

    var isParakeetAvailable: Bool {
        #if PARAKEET_AVAILABLE
        return true
        #else
        return false
        #endif
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "stt-engine") ?? "whisper"
        let choice = STTEngineChoice(rawValue: saved) ?? .whisper

        // If Parakeet was selected but isn't available in this build, fall back to Whisper
        #if !PARAKEET_AVAILABLE
        self.activeChoice = .whisper
        #else
        self.activeChoice = choice
        #endif

        subscribeToActiveEngine()
    }

    // MARK: - Engine Routing

    func startRecording() {
        switch activeChoice {
        case .whisper:
            whisperEngine.startRecording()
        case .parakeet:
            #if PARAKEET_AVAILABLE
            if parakeetEngine.isModelLoaded {
                parakeetEngine.startRecording()
            } else {
                // Fallback to Whisper if Parakeet models aren't ready
                print("⚠️ ROUTER | Parakeet not ready, falling back to Whisper")
                EventReporter.shared.capture(level: .warning, engine: "parakeet",
                    event: "fallback_to_whisper", message: "Parakeet model not ready, using Whisper")
                whisperEngine.startRecording()
            }
            #else
            whisperEngine.startRecording()
            #endif
        }
    }

    func stopRecording() {
        // Stop whichever engine is actually recording
        if whisperEngine.isRecording {
            whisperEngine.stopRecording()
        }
        #if PARAKEET_AVAILABLE
        if parakeetEngine.isRecording {
            parakeetEngine.stopRecording()
        }
        #endif
    }

    func transcribe() async -> String? {
        // Route to whichever engine has audio buffered
        #if PARAKEET_AVAILABLE
        if activeChoice == .parakeet && parakeetEngine.isModelLoaded {
            return await parakeetEngine.transcribe()
        }
        #endif
        return await whisperEngine.transcribe()
    }

    func cancel() {
        whisperEngine.cancel()
        #if PARAKEET_AVAILABLE
        parakeetEngine.cancel()
        #endif
    }

    // MARK: - Engine Switching

    func switchEngine(to choice: STTEngineChoice) {
        guard !isRecording, !isTranscribing else {
            print("⚠️ ROUTER | cannot switch engine while recording or transcribing")
            return
        }

        #if !PARAKEET_AVAILABLE
        if choice == .parakeet {
            print("⚠️ ROUTER | Parakeet not available in this build")
            return
        }
        #endif

        activeChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "stt-engine")
        subscribeToActiveEngine()
        print("🔄 ROUTER | switched to \(choice.rawValue)")

        // Initialize Parakeet models if switching to it for the first time
        #if PARAKEET_AVAILABLE
        if choice == .parakeet, !parakeetEngine.isModelLoaded {
            Task {
                await parakeetEngine.initialize()
                parakeetEngine.prewarm()
            }
        }
        #endif
    }

    // MARK: - Combine Property Forwarding

    private func subscribeToActiveEngine() {
        cancellables.removeAll()

        switch activeChoice {
        case .whisper:
            whisperEngine.$isRecording.assign(to: &$isRecording)
            whisperEngine.$isTranscribing.assign(to: &$isTranscribing)
            whisperEngine.$audioLevel.assign(to: &$audioLevel)
            whisperEngine.$liveTranscript.assign(to: &$liveTranscript)

        case .parakeet:
            #if PARAKEET_AVAILABLE
            parakeetEngine.$isRecording.assign(to: &$isRecording)
            parakeetEngine.$isTranscribing.assign(to: &$isTranscribing)
            parakeetEngine.$audioLevel.assign(to: &$audioLevel)
            parakeetEngine.$liveTranscript.assign(to: &$liveTranscript)
            #else
            whisperEngine.$isRecording.assign(to: &$isRecording)
            whisperEngine.$isTranscribing.assign(to: &$isTranscribing)
            whisperEngine.$audioLevel.assign(to: &$audioLevel)
            whisperEngine.$liveTranscript.assign(to: &$liveTranscript)
            #endif
        }
    }
}

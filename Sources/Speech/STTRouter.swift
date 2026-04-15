// STTRouter.swift
// Single-engine STT router — thin wrapper around ParakeetEngine that forwards
// @Published properties via Combine for SwiftUI binding compatibility.

import Combine
import SwiftUI

@MainActor
class STTRouter: ObservableObject {
    let parakeetEngine = ParakeetEngine()

    // Forwarded from ParakeetEngine
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var audioLevel: Float = 0
    @Published var liveTranscript: String = ""
    @Published var recordingInterrupted = false
    @Published var isRecovering = false
    @Published var inputFormatReady = true

    var isModelLoaded: Bool { parakeetEngine.isModelLoaded }
    var inputDeviceName: String { parakeetEngine.inputDeviceName }

    init() {
        parakeetEngine.$isRecording.assign(to: &$isRecording)
        parakeetEngine.$isTranscribing.assign(to: &$isTranscribing)
        parakeetEngine.$audioLevel.assign(to: &$audioLevel)
        parakeetEngine.$liveTranscript.assign(to: &$liveTranscript)
        parakeetEngine.$recordingInterrupted.assign(to: &$recordingInterrupted)
        parakeetEngine.$isRecovering.assign(to: &$isRecovering)
        parakeetEngine.$inputFormatReady.assign(to: &$inputFormatReady)
    }

    // MARK: - Recording

    func startRecording() -> Bool {
        return parakeetEngine.startRecording()
    }

    func stopRecording() {
        parakeetEngine.stopRecording()
    }

    func transcribe() async -> String? {
        return await parakeetEngine.transcribe()
    }

    func cancel() {
        parakeetEngine.cancel()
    }
}

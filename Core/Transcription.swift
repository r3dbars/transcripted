import Foundation
import Speech

class Transcription: ObservableObject {
    @Published var currentText: String = ""
    @Published var isProcessing: Bool = false
    @Published var error: String?
    @Published var justFinished: Bool = false

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hasCopied: Bool = false

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale.current)
        recognizer?.defaultTaskHint = .dictation

        if recognizer?.supportsOnDeviceRecognition == true {
            print("✓ On-device speech recognition available")
        }
    }

    func start() {
        task?.cancel()
        task = nil

        currentText = ""
        isProcessing = true
        error = nil
        hasCopied = false
        justFinished = false

        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request = request else {
            error = "Unable to create recognition request"
            isProcessing = false
            return
        }

        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = false
        }

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            var isFinal = false

            if let result = result {
                DispatchQueue.main.async {
                    self.currentText = result.bestTranscription.formattedString
                    self.error = nil
                    isFinal = result.isFinal

                    if isFinal {
                        self.isProcessing = false
                    }
                }
            }

            if let error = error {
                let nsError = error as NSError
                if nsError.code != 203 && nsError.code != 216 {
                    DispatchQueue.main.async {
                        self.error = error.localizedDescription
                        self.isProcessing = false
                    }
                } else if isFinal {
                    DispatchQueue.main.async {
                        if self.currentText.isEmpty {
                            self.error = "No speech detected"
                        }
                        self.isProcessing = false
                    }
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func stop() {
        request?.endAudio()
        task?.finish()
        isProcessing = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            if !self.currentText.isEmpty && !self.hasCopied {
                self.hasCopied = true
                Clipboard.copy(self.currentText)

                // Signal that transcription is complete
                self.justFinished = true
            }
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        request = nil
        currentText = ""
        isProcessing = false
        error = nil
        hasCopied = false
        justFinished = false
    }
}

import Foundation
import Speech
import AppKit

/// Manages speech recognition model availability and user prompts
@available(macOS 26.0, *)
class SpeechModelManager: ObservableObject {
    @Published var isOnDeviceAvailable: Bool = false
    @Published var shouldShowModelPrompt: Bool = false
    @Published var modelCheckComplete: Bool = false

    private let userDefaultsKey = "hasPromptedForSpeechModel"

    /// Check if on-device speech recognition model is available
    func checkModelAvailability() async {
        // Create a test transcriber to check if on-device works
        let testTranscriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],  // Empty = on-device only
            reportingOptions: [],
            attributeOptions: []
        )

        // Try to get format - this will succeed if model is available
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [testTranscriber])

        await MainActor.run {
            self.isOnDeviceAvailable = (format != nil)
            self.modelCheckComplete = true

            // Show prompt if model not available and user hasn't been prompted before
            if !self.isOnDeviceAvailable && !self.hasBeenPrompted {
                self.shouldShowModelPrompt = true
            }
        }
    }

    /// Open System Settings to Keyboard > Dictation for model download
    func openDictationSettings() {
        // Open System Settings to Keyboard preferences
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
            NSWorkspace.shared.open(url)
        }

        markAsPrompted()
    }

    /// User chose to use server-backed instead
    func useServerBacked() {
        markAsPrompted()
        shouldShowModelPrompt = false
    }

    /// Check if user has been prompted before
    var hasBeenPrompted: Bool {
        return UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    /// Mark that user has been prompted
    private func markAsPrompted() {
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
    }

    /// Reset prompt state (for testing)
    func resetPromptState() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        shouldShowModelPrompt = false
    }
}

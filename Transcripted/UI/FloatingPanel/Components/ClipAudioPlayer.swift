import SwiftUI
import AVFoundation

// MARK: - ClipAudioPlayer

/// Lightweight wrapper around AVAudioPlayer for speaker clip playback.
/// @MainActor ensures @Published state updates are safe for SwiftUI observation
/// from multiple SpeakerNamingCard instances.
@available(macOS 14.0, *)
@MainActor
class ClipAudioPlayer: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentClipURL: URL?

    private var player: AVAudioPlayer?

    func play(url: URL) {
        stop()  // stop any current playback

        // Load audio file on a background thread to avoid blocking the main thread
        // with file I/O — especially with 7 speaker clips being played rapidly.
        let capturedURL = url
        Task.detached { [weak self] in
            do {
                let audioPlayer = try AVAudioPlayer(contentsOf: capturedURL)
                await MainActor.run {
                    guard let self else { return }
                    self.player = audioPlayer
                    self.player?.delegate = self
                    self.player?.play()
                    self.isPlaying = true
                    self.currentClipURL = capturedURL
                }
            } catch {
                AppLogger.ui.warning("Failed to play speaker clip", ["error": error.localizedDescription])
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentClipURL = nil
    }
}

// AVAudioPlayerDelegate must be nonisolated for the callback
extension ClipAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.currentClipURL = nil
        }
    }
}

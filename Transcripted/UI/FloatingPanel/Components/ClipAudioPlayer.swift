import SwiftUI
import AVFoundation

// MARK: - ClipAudioPlayer

/// Lightweight wrapper around AVAudioPlayer for speaker clip playback.
@available(macOS 14.0, *)
class ClipAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentClipURL: URL?

    private var player: AVAudioPlayer?

    func play(url: URL) {
        stop()  // stop any current playback

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.play()
            isPlaying = true
            currentClipURL = url
        } catch {
            AppLogger.ui.warning("Failed to play speaker clip", ["error": error.localizedDescription])
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentClipURL = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.currentClipURL = nil
        }
    }
}

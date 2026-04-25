import AppKit
import Foundation

@MainActor
enum SpeakerClipPlayback {
    static let stateDidChangeNotification = Notification.Name("SpeakerClipPlaybackStateDidChange")

    private final class PlaybackDelegate: NSObject, NSSoundDelegate {
        func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
            Task { @MainActor in
                SpeakerClipPlayback.finish(sound)
            }
        }
    }

    private static var activeSound: NSSound?
    private static var activeURL: URL?
    private static var progressTimer: Timer?
    private static let playbackDelegate = PlaybackDelegate()

    static func play(_ url: URL) {
        if activeURL == url, activeSound?.isPlaying == true {
            stop()
            return
        }

        activeSound?.stop()
        progressTimer?.invalidate()
        progressTimer = nil
        activeURL = url
        activeSound = NSSound(contentsOf: url, byReference: false)
        activeSound?.delegate = playbackDelegate
        if activeSound?.play() == true {
            startProgressUpdates()
            notifyStateDidChange()
        } else {
            stop()
        }
    }

    static func isPlaying(_ url: URL) -> Bool {
        activeURL == url && activeSound?.isPlaying == true
    }

    static func isActive(_ url: URL) -> Bool {
        activeURL == url
    }

    static func progress(for url: URL) -> Double? {
        guard activeURL == url,
              let sound = activeSound,
              sound.duration > 0 else {
            return nil
        }
        return min(max(sound.currentTime / sound.duration, 0), 1)
    }

    static func timeLabel(for url: URL) -> String? {
        guard activeURL == url,
              let sound = activeSound,
              sound.duration > 0 else {
            return nil
        }
        return "\(formatTime(sound.currentTime)) / \(formatTime(sound.duration))"
    }

    static func stop() {
        activeSound?.stop()
        activeSound?.delegate = nil
        activeSound = nil
        activeURL = nil
        progressTimer?.invalidate()
        progressTimer = nil
        notifyStateDidChange()
    }

    private static func finish(_ sound: NSSound) {
        guard activeSound === sound else { return }
        activeSound?.delegate = nil
        activeSound = nil
        activeURL = nil
        progressTimer?.invalidate()
        progressTimer = nil
        notifyStateDidChange()
    }

    private static func startProgressUpdates() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in
                guard let sound = activeSound else {
                    progressTimer?.invalidate()
                    progressTimer = nil
                    notifyStateDidChange()
                    return
                }

                if !sound.isPlaying && sound.duration > 0 && sound.currentTime >= sound.duration {
                    finish(sound)
                    return
                }

                notifyStateDidChange()
            }
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let wholeSeconds = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }

    private static func notifyStateDidChange() {
        NotificationCenter.default.post(
            name: stateDidChangeNotification,
            object: activeURL
        )
    }
}

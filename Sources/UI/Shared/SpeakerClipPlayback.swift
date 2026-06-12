import AppKit
import Foundation

@MainActor
enum SpeakerClipPlayback {
    static let stateDidChangeNotification = Notification.Name("SpeakerClipPlaybackStateDidChange")

    private final class PlaybackDelegate: NSObject, NSSoundDelegate {
        func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
            Task { @MainActor in
                SpeakerClipPlayback.finishIfActive(sound)
            }
        }
    }

    private static let playbackDelegate = PlaybackDelegate()
    private static var activeSound: NSSound?
    private static var activeURL: URL?

    static func play(_ url: URL) {
        if activeURL == url, activeSound?.isPlaying == true {
            stop()
            return
        }

        activeSound?.stop()
        activeURL = url
        activeSound = NSSound(contentsOf: url, byReference: false)
        activeSound?.delegate = playbackDelegate
        if activeSound?.play() == true {
            notifyStateDidChange()
        } else {
            stop()
        }
    }

    static func isPlaying(_ url: URL) -> Bool {
        activeURL == url && activeSound?.isPlaying == true
    }

    static func stop() {
        activeSound?.delegate = nil
        activeSound?.stop()
        activeSound = nil
        activeURL = nil
        notifyStateDidChange()
    }

    private static func finishIfActive(_ sound: NSSound) {
        guard activeSound === sound else { return }
        activeSound?.delegate = nil
        activeSound = nil
        activeURL = nil
        notifyStateDidChange()
    }

    private static func notifyStateDidChange() {
        NotificationCenter.default.post(
            name: stateDidChangeNotification,
            object: activeURL
        )
    }
}

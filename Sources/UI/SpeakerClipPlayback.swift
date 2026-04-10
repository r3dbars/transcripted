import AppKit
import Foundation

@MainActor
enum SpeakerClipPlayback {
    private static var activeSound: NSSound?
    private static var activeURL: URL?

    static func play(_ url: URL) {
        if activeURL == url, activeSound?.isPlaying == true {
            activeSound?.stop()
            activeSound = nil
            activeURL = nil
            return
        }

        activeSound?.stop()
        activeURL = url
        activeSound = NSSound(contentsOf: url, byReference: false)
        activeSound?.play()
    }

    static func stop() {
        activeSound?.stop()
        activeSound = nil
        activeURL = nil
    }
}

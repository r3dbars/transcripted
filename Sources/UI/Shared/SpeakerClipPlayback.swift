import AppKit
import Foundation

/// Plays one persisted speaker sample clip at a time.
///
/// An `ObservableObject` singleton so SwiftUI rows can observe playback
/// directly: `@Published activeURL` invalidates every observing view on
/// play/stop/finish, guaranteed by the framework. This replaced a
/// notification + version-counter scheme after a traced repro showed the
/// state bump landing in the hosting section without the `LazyVStack` rows
/// ever re-rendering — the play buttons stayed on the play glyph while
/// audio was audibly playing. The static facade and the state-change
/// notification remain for the AppKit consumer (`SpeakerNamingSheet`) and
/// existing call sites.
@MainActor
final class SpeakerClipPlayback: ObservableObject {
    static let shared = SpeakerClipPlayback()
    static let stateDidChangeNotification = Notification.Name("SpeakerClipPlaybackStateDidChange")

    /// The clip currently playing, if any. Deliberately the source of truth
    /// for "is this clip playing": it flips on our own play/stop/finish
    /// transitions rather than consulting `NSSound.isPlaying` at read time,
    /// so observers and the AX layer always agree with what was started.
    @Published private(set) var activeURL: URL?

    private final class PlaybackDelegate: NSObject, NSSoundDelegate {
        func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
            Task { @MainActor in
                SpeakerClipPlayback.shared.finishIfActive(sound)
            }
        }
    }

    private let playbackDelegate = PlaybackDelegate()
    private var activeSound: NSSound?

    private init() {}

    // MARK: - Static facade (AppKit consumers, existing call sites)

    static func play(_ url: URL) { shared.play(url) }
    static func isPlaying(_ url: URL) -> Bool { shared.isPlaying(url) }
    static func stop() { shared.stop() }

    // MARK: - Instance API

    func play(_ url: URL) {
        if activeURL == url {
            stop()
            return
        }

        activeSound?.delegate = nil
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

    func isPlaying(_ url: URL) -> Bool {
        activeURL == url
    }

    func stop() {
        activeSound?.delegate = nil
        activeSound?.stop()
        activeSound = nil
        activeURL = nil
        notifyStateDidChange()
    }

    private func finishIfActive(_ sound: NSSound) {
        guard activeSound === sound else { return }
        activeSound?.delegate = nil
        activeSound = nil
        activeURL = nil
        notifyStateDidChange()
    }

    private func notifyStateDidChange() {
        NotificationCenter.default.post(
            name: Self.stateDidChangeNotification,
            object: activeURL
        )
    }
}

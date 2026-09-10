import AppKit
import AVFoundation
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
    @Published private(set) var activeRetainedSample: SpeakerRetainedAudioSample?

    private final class PlaybackDelegate: NSObject, NSSoundDelegate {
        func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
            Task { @MainActor in
                SpeakerClipPlayback.shared.finishIfActive(sound)
            }
        }
    }

    private let playbackDelegate = PlaybackDelegate()
    private var activeSound: NSSound?
    private let retainedAudioPlayer: AVPlayer
    private var retainedAudioObservers: [NSObjectProtocol] = []
    private var retainedAudioStatusObserver: NSKeyValueObservation?

    init(retainedAudioPlayer: AVPlayer = AVPlayer()) {
        self.retainedAudioPlayer = retainedAudioPlayer
    }

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

        stop()
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

    /// Stream a short range from retained audio instead of loading a long
    /// meeting into NSSound or saving an unconfirmed global profile sample.
    func play(_ sample: SpeakerRetainedAudioSample) {
        if activeRetainedSample == sample {
            stop()
            return
        }
        stop()
        guard sample.startTime.isFinite, sample.startTime >= 0,
              sample.duration.isFinite, sample.duration > 0, sample.duration <= 8,
              let url = OwnFileResolver.resolveExistingFile(candidateURLs: [sample.url]) else { return }

        let item = AVPlayerItem(url: url)
        item.forwardPlaybackEndTime = CMTime(seconds: sample.startTime + sample.duration, preferredTimescale: 600)
        let player = retainedAudioPlayer
        player.replaceCurrentItem(with: item)
        activeRetainedSample = sample
        retainedAudioStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.retainedAudioPlayer.currentItem === item,
                      item.status == .failed else { return }
                self.stop()
            }
        }
        for name in [Notification.Name.AVPlayerItemDidPlayToEndTime, .AVPlayerItemFailedToPlayToEndTime] {
            retainedAudioObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: item,
                queue: .main
            ) { [weak self, weak item] _ in
                Task { @MainActor in
                    guard let self, let item, self.retainedAudioPlayer.currentItem === item else { return }
                    self.stop()
                }
            })
        }
        player.seek(
            to: CMTime(seconds: sample.startTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak item] finished in
            Task { @MainActor in
                guard let self, let item, self.retainedAudioPlayer.currentItem === item else { return }
                guard finished else {
                    self.stop()
                    return
                }
                self.retainedAudioPlayer.play()
                self.notifyStateDidChange()
            }
        }
    }

    func isPlaying(_ sample: SpeakerRetainedAudioSample) -> Bool {
        activeRetainedSample == sample
    }

    func stop() {
        activeSound?.delegate = nil
        activeSound?.stop()
        activeSound = nil
        activeURL = nil
        retainedAudioStatusObserver?.invalidate()
        retainedAudioStatusObserver = nil
        retainedAudioPlayer.pause()
        retainedAudioPlayer.replaceCurrentItem(with: nil)
        activeRetainedSample = nil
        retainedAudioObservers.forEach(NotificationCenter.default.removeObserver)
        retainedAudioObservers.removeAll()
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

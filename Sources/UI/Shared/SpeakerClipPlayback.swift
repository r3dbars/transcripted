import AppKit
import AVFoundation
import CryptoKit
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
/// notification remain for the AppKit consumer
/// (`NotchIslandSpeakerReviewControls`) and existing call sites.
@MainActor
final class SpeakerClipPlayback: ObservableObject {
    static let shared = SpeakerClipPlayback()
    static let stateDidChangeNotification = Notification.Name("SpeakerClipPlaybackStateDidChange")

    /// The clip currently playing, if any. Deliberately the source of truth
    /// for "is this clip playing": it flips on our own play/stop/finish
    /// transitions rather than consulting `NSSound.isPlaying` at read time,
    /// so observers and the AX layer always agree with what was started.
    @Published private(set) var activeURL: URL?
    /// Quote validated against the same wav bytes that started playing.
    /// Nil when the sidecar does not describe those bytes, or nothing is playing.
    @Published private(set) var activeValidatedQuote: String?
    /// SHA-256 of the wav `Data` this play loaded. Same bytes as the quote
    /// and the `NSSound`. Nil when nothing is playing.
    private(set) var activeWavSHA256: String?
    /// The wav bytes `play` loaded for the current clip. Quote and sound
    /// both come from this `Data`. Tests replace the file after load and
    /// still read this, not a live reread.
    private(set) var lastLoadedPlay: LoadedPlay?
    /// Test seam: start playback of already-loaded wav bytes. Production
    /// leaves this nil and uses `NSSound`.
    var playLoadedWavData: ((Data) -> Bool)?
    @Published private(set) var activeRetainedSample: SpeakerRetainedAudioSample?

    struct LoadedPlay {
        let wavData: Data
        let quote: String?
        let sha256: String
    }

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
    static func progress(of url: URL) -> Double? { shared.progress(of: url) }
    static func stop() { shared.stop() }

    // MARK: - Instance API

    func play(_ url: URL) {
        if activeURL == url {
            stop()
            return
        }

        stop()
        guard let wavData = try? Data(contentsOf: url), !wavData.isEmpty else { return }
        let quote = SpeakerClipSidecarQuote.validatedText(nextTo: url, wavData: wavData)
        let digest = SpeakerClipSidecarQuote.sha256Hex(wavData)
        lastLoadedPlay = LoadedPlay(wavData: wavData, quote: quote, sha256: digest)
        if let playLoadedWavData {
            guard playLoadedWavData(wavData) else { return }
            activeURL = url
            activeValidatedQuote = quote
            activeWavSHA256 = digest
            notifyStateDidChange()
            return
        }
        guard let sound = NSSound(data: wavData) else { return }
        sound.delegate = playbackDelegate
        activeURL = url
        activeValidatedQuote = quote
        activeWavSHA256 = digest
        activeSound = sound
        if sound.play() {
            notifyStateDidChange()
        } else {
            stop()
        }
    }

    func isPlaying(_ url: URL) -> Bool {
        activeURL == url
    }

    /// How far the clip at `url` has played, 0...1, or nil when it isn't the
    /// clip playing. Drives the island's ring around a playing sample.
    func progress(of url: URL) -> Double? {
        guard activeURL == url, let activeSound, activeSound.duration > 0 else { return nil }
        return min(1, max(0, activeSound.currentTime / activeSound.duration))
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
        activeValidatedQuote = nil
        activeWavSHA256 = nil
        lastLoadedPlay = nil
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
        activeValidatedQuote = nil
        activeWavSHA256 = nil
        lastLoadedPlay = nil
        notifyStateDidChange()
    }

    private func notifyStateDidChange() {
        NotificationCenter.default.post(
            name: Self.stateDidChangeNotification,
            object: activeURL
        )
    }
}

/// Decodes the sidecar JSON by key so this module does not name the Core
/// sidecar type. The quote is returned only when it describes `wavData`.
enum SpeakerClipSidecarQuote {
    struct Payload: Decodable {
        var sampleText: String
        var formatVersion: Int
        var wavByteCount: Int
        var wavSHA256: String
    }

    static func validatedText(nextTo clipURL: URL, wavData: Data) -> String? {
        let url = clipURL.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.formatVersion == 1,
              payload.wavByteCount > 0,
              !payload.wavSHA256.isEmpty,
              wavData.count == payload.wavByteCount,
              sha256Hex(wavData) == payload.wavSHA256.lowercased() else {
            return nil
        }
        let text = payload.sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

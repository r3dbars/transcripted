// DictationPlaybackController.swift
// Inline playback for the Dictations page: one take plays at a time.

import AVFoundation
import Combine
import Foundation

/// What the controller needs from a player. `AVDictationAudioPlayer` is the
/// real one; tests pass a fake.
@MainActor
protocol DictationAudioPlayback: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    /// Called once when playback reaches the end.
    var onFinish: (() -> Void)? { get set }
    func play() -> Bool
    func pause()
    func stop()
}

/// Owns the page's single player. Starting a take stops whatever was
/// playing; pausing keeps the player open; reaching the end, `stop()`, or
/// leaving the page folds the card back to its resting bar.
///
/// Output only: `AVAudioPlayer` plays a file to the default output and never
/// opens an input device, so a Bluetooth headset isn't pushed into call mode.
@MainActor
final class DictationPlaybackController: ObservableObject {
    enum Phase: Equatable {
        case playing
        case paused
    }

    struct Session: Equatable {
        let entryID: String
        var phase: Phase
        let duration: TimeInterval
    }

    @Published private(set) var session: Session?
    private var player: DictationAudioPlayback?
    private let makePlayer: @MainActor (URL) throws -> DictationAudioPlayback

    init(makePlayer: @escaping @MainActor (URL) throws -> DictationAudioPlayback = { try AVDictationAudioPlayer(url: $0) }) {
        self.makePlayer = makePlayer
    }

    func isActive(_ entryID: String) -> Bool {
        session?.entryID == entryID
    }

    func isPlaying(_ entryID: String) -> Bool {
        session?.entryID == entryID && session?.phase == .playing
    }

    /// Play, pause, or resume `entryID`. Starting a different take stops the
    /// current one first and asks `resolveURL` for the file (only then, so a
    /// pause never touches disk). Returns false when there's no file or it
    /// can't be played; the page is then left with nothing playing.
    @discardableResult
    func togglePlayback(entryID: String, resolveURL: () -> URL?) -> Bool {
        if let current = session, current.entryID == entryID, let player {
            switch current.phase {
            case .playing:
                player.pause()
                session?.phase = .paused
            case .paused:
                guard player.play() else {
                    stop()
                    return false
                }
                session?.phase = .playing
            }
            return true
        }

        stop()
        guard let url = resolveURL(), let newPlayer = try? makePlayer(url) else { return false }
        newPlayer.onFinish = { [weak self, weak newPlayer] in
            guard let self, let newPlayer, self.player === newPlayer else { return }
            self.stop()
        }
        guard newPlayer.play() else {
            newPlayer.onFinish = nil
            return false
        }
        player = newPlayer
        session = Session(entryID: entryID, phase: .playing, duration: max(0, newPlayer.duration))
        return true
    }

    /// Seconds played of `entryID`, or 0 when it isn't the open take.
    func currentTime(for entryID: String) -> TimeInterval {
        guard let session, session.entryID == entryID, let player else { return 0 }
        return min(max(0, player.currentTime), session.duration)
    }

    /// 0...1 progress of `entryID`.
    func progress(for entryID: String) -> Double {
        guard let session, session.entryID == entryID, session.duration > 0 else { return 0 }
        return currentTime(for: entryID) / session.duration
    }

    /// Moves the open take's playhead to `fraction` (clamped to 0...1).
    func seek(entryID: String, toFraction fraction: Double) {
        guard let session, session.entryID == entryID, let player else { return }
        let clamped = min(max(fraction, 0), 1)
        player.currentTime = clamped * session.duration
        // A paused card isn't redrawing on its own.
        objectWillChange.send()
    }

    /// Moves the open take's playhead by `delta` seconds (VoiceOver adjust).
    func seek(entryID: String, by delta: TimeInterval) {
        guard let session, session.entryID == entryID, session.duration > 0 else { return }
        let target = currentTime(for: entryID) + delta
        seek(entryID: entryID, toFraction: target / session.duration)
    }

    /// Stops and folds back whatever is open.
    func stop() {
        player?.onFinish = nil
        player?.stop()
        player = nil
        session = nil
    }

    /// Stops `entryID` if it's the open take (it was deleted, say).
    func stop(entryID: String) {
        if session?.entryID == entryID {
            stop()
        }
    }
}

/// `AVAudioPlayer` behind `DictationAudioPlayback`.
@MainActor
final class AVDictationAudioPlayer: NSObject, DictationAudioPlayback, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var onFinish: (() -> Void)?

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
        player.prepareToPlay()
    }

    var duration: TimeInterval { player.duration }

    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }

    func play() -> Bool { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }
}

/// Kept-audio facts for a card, loaded lazily off the main actor: whether
/// the file is still there and how long it runs. Nothing is read until a
/// card asks, and each entry is read once.
@MainActor
final class DictationAudioInfoStore: ObservableObject {
    struct Info: Equatable {
        let isAvailable: Bool
        let duration: TimeInterval?
    }

    @Published private(set) var infos: [String: Info] = [:]
    private var inFlight: Set<String> = []

    private static func key(for entry: SavedDictationEntry) -> String? {
        entry.audioRelativePath.map { "\(entry.id)|\($0)" }
    }

    func info(for entry: SavedDictationEntry) -> Info? {
        Self.key(for: entry).flatMap { infos[$0] }
    }

    func load(_ entry: SavedDictationEntry) async {
        guard let key = Self.key(for: entry),
              let relativePath = entry.audioRelativePath,
              infos[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        let folder = entry.url.deletingLastPathComponent()
        let info = await Task.detached(priority: .utility) {
            guard let url = DictationAudioArchive.resolveURL(relativePath: relativePath, dictationsFolder: folder) else {
                return Info(isAvailable: false, duration: nil)
            }
            return Info(isAvailable: true, duration: Self.duration(of: url))
        }.value
        infos[key] = info
    }

    /// The file to play right now. Resolved again on every play because the
    /// WAV turns into an M4A a few seconds after a take is saved.
    func playableURL(for entry: SavedDictationEntry) -> URL? {
        guard let relativePath = entry.audioRelativePath else { return nil }
        let url = DictationAudioArchive.resolveURL(
            relativePath: relativePath,
            dictationsFolder: entry.url.deletingLastPathComponent()
        )
        if url == nil, let key = Self.key(for: entry) {
            infos[key] = Info(isAvailable: false, duration: nil)
        }
        return url
    }

    nonisolated private static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.fileFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }
}

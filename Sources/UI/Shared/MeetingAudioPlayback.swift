import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class MeetingAudioPlayback: NSObject, ObservableObject, NSSoundDelegate {
    static let shared = MeetingAudioPlayback()

    @Published private(set) var activeAttachmentID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var unavailableAttachmentID: String?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var sounds: [NSSound] = []
    private var progressTimer: Timer?

    func toggle(_ attachment: MeetingAudioAttachment) {
        if activeAttachmentID == attachment.id {
            if isPlaying {
                pause()
            } else if isPaused {
                resume()
            } else {
                play(attachment)
            }
            return
        }

        play(attachment)
    }

    func play(_ attachment: MeetingAudioAttachment) {
        stop()

        let loadedSounds = attachment.playbackURLs.compactMap { url in
            NSSound(contentsOf: url, byReference: true)
        }

        guard !loadedSounds.isEmpty else {
            unavailableAttachmentID = attachment.id
            NSSound.beep()
            return
        }

        unavailableAttachmentID = nil
        activeAttachmentID = attachment.id
        sounds = loadedSounds
        duration = loadedSounds.map(\.duration).max() ?? 0
        currentTime = 0
        isPlaying = true
        isPaused = false

        for sound in sounds {
            sound.delegate = self
            sound.currentTime = 0
            sound.play()
        }

        startProgressTimer()
    }

    func pause() {
        guard isPlaying else { return }
        for sound in sounds {
            sound.pause()
        }
        stopProgressTimer()
        isPlaying = false
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        var resumedAnySound = false
        for sound in sounds {
            resumedAnySound = sound.resume() || resumedAnySound
        }
        isPlaying = resumedAnySound
        isPaused = !resumedAnySound
        if resumedAnySound {
            startProgressTimer()
        }
    }

    func stop() {
        stopProgressTimer()
        for sound in sounds {
            sound.stop()
            sound.delegate = nil
        }
        sounds.removeAll()
        activeAttachmentID = nil
        isPlaying = false
        isPaused = false
        unavailableAttachmentID = nil
        currentTime = 0
        duration = 0
    }

    func isActive(_ attachment: MeetingAudioAttachment) -> Bool {
        activeAttachmentID == attachment.id
    }

    func seek(_ attachment: MeetingAudioAttachment, progress: Double) {
        guard isActive(attachment), duration > 0 else { return }
        let clampedProgress = min(max(progress, 0), 1)
        let targetTime = duration * clampedProgress

        for sound in sounds {
            let soundDuration = max(sound.duration, 0)
            let seekTime = min(targetTime, soundDuration)
            sound.currentTime = seekTime
            if isPlaying, !sound.isPlaying, seekTime < soundDuration {
                sound.play()
            }
        }

        currentTime = targetTime
    }

    func skip(_ attachment: MeetingAudioAttachment, by seconds: TimeInterval) {
        guard isActive(attachment), duration > 0 else { return }
        let targetTime = min(max(currentTime + seconds, 0), duration)
        seek(attachment, progress: targetTime / duration)
    }

    func progress(for attachment: MeetingAudioAttachment) -> Double {
        guard isActive(attachment), duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    func timeLabel(for attachment: MeetingAudioAttachment) -> String {
        guard isActive(attachment), duration > 0 else { return "0:00" }
        return "\(Self.formatTime(currentTime)) / \(Self.formatTime(duration))"
    }

    func compactTimeLabel(for attachment: MeetingAudioAttachment) -> String {
        guard isActive(attachment), duration > 0 else { return "0:00 / --:--" }
        return "\(Self.formatTime(currentTime)) / \(Self.formatTime(duration))"
    }

    func buttonTitle(for attachment: MeetingAudioAttachment) -> String {
        if unavailableAttachmentID == attachment.id { return "Unavailable" }
        guard isActive(attachment) else { return "Play" }
        if isPlaying { return "Pause" }
        if isPaused { return "Resume" }
        return "Play"
    }

    func symbolName(for attachment: MeetingAudioAttachment) -> String {
        if unavailableAttachmentID == attachment.id { return "exclamationmark.triangle.fill" }
        guard isActive(attachment) else { return "play.fill" }
        if isPlaying { return "pause.fill" }
        return "play.fill"
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying finishedPlaying: Bool) {
        Task { @MainActor [weak self] in
            self?.handleSoundFinished()
        }
    }

    private func handleSoundFinished() {
        guard !isPaused else { return }
        guard !sounds.contains(where: { $0.isPlaying }) else { return }
        stop()
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePlaybackTime()
            }
        }
        progressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updatePlaybackTime()
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updatePlaybackTime() {
        guard !sounds.isEmpty, duration > 0 else {
            currentTime = 0
            return
        }

        let latestTime = sounds.map(\.currentTime).max() ?? 0
        currentTime = min(max(latestTime, 0), duration)
    }

    private static func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct MeetingAudioScrubber: View {
    let attachment: MeetingAudioAttachment
    var width: CGFloat?
    var showsTime = true

    @ObservedObject private var playback = MeetingAudioPlayback.shared

    var body: some View {
        HStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { playback.progress(for: attachment) },
                    set: { playback.seek(attachment, progress: $0) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .disabled(!canScrub)

            if showsTime {
                Text(playback.timeLabel(for: attachment))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 78, alignment: .trailing)
            }
        }
        .frame(width: width, alignment: .leading)
        .help(canScrub ? "Drag to scrub meeting audio" : "Start playback before scrubbing")
    }

    private var canScrub: Bool {
        playback.isActive(attachment) && playback.duration > 0
    }
}

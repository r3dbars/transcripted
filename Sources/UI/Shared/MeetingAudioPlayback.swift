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
    @Published private(set) var unavailablePlaybackID: String?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var activeChoiceID: String?

    private var sounds: [NSSound] = []
    private var progressTimer: Timer?

    func toggle(_ attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice? = nil) {
        let choiceID = (choice ?? attachment.defaultPlaybackChoice)?.id
        if activeAttachmentID == attachment.id && activeChoiceID == choiceID {
            if isPlaying {
                pause()
            } else if isPaused {
                resume()
            } else {
                play(attachment, choice: choice)
            }
            return
        }

        play(attachment, choice: choice)
    }

    func play(_ attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice? = nil) {
        play(attachment, choice: choice, startTime: 0, startPaused: false)
    }

    func switchSource(_ attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice) {
        guard isActive(attachment) else {
            play(attachment, choice: choice)
            return
        }

        play(
            attachment,
            choice: choice,
            startTime: currentTime,
            startPaused: isPaused
        )
    }

    private func play(
        _ attachment: MeetingAudioAttachment,
        choice: MeetingAudioPlaybackChoice?,
        startTime: TimeInterval,
        startPaused: Bool
    ) {
        stop()

        let requestedChoice = choice ?? attachment.defaultPlaybackChoice
        guard let loadedPlayback = loadPlaybackSounds(for: attachment, preferredChoice: requestedChoice) else {
            unavailablePlaybackID = playbackID(for: attachment, choice: requestedChoice)
            NSSound.beep()
            return
        }

        let loadedSounds = loadedPlayback.sounds

        unavailablePlaybackID = nil
        activeAttachmentID = attachment.id
        activeChoiceID = loadedPlayback.choice.id
        sounds = loadedSounds
        duration = loadedSounds.map(\.duration).max() ?? 0
        currentTime = min(max(startTime, 0), duration)
        isPlaying = !startPaused
        isPaused = startPaused

        for sound in sounds {
            sound.delegate = self
            sound.currentTime = min(currentTime, max(sound.duration, 0))
            sound.play()
            if startPaused {
                sound.pause()
            }
        }

        if startPaused {
            stopProgressTimer()
        } else {
            startProgressTimer()
        }
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
        activeChoiceID = nil
        isPlaying = false
        isPaused = false
        unavailablePlaybackID = nil
        currentTime = 0
        duration = 0
    }

    func stopIfActive(attachmentIDs: Set<String>) {
        guard let activeAttachmentID, attachmentIDs.contains(activeAttachmentID) else {
            return
        }
        stop()
    }

    func isActive(_ attachment: MeetingAudioAttachment) -> Bool {
        activeAttachmentID == attachment.id
    }

    func isActive(_ attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice?) -> Bool {
        guard activeAttachmentID == attachment.id else { return false }
        guard let choice else { return true }
        return activeChoiceID == choice.id
    }

    func activeChoice(for attachment: MeetingAudioAttachment) -> MeetingAudioPlaybackChoice? {
        guard activeAttachmentID == attachment.id else { return nil }
        return attachment.playbackChoice(id: activeChoiceID)
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

    func buttonTitle(for attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice? = nil) -> String {
        if isUnavailable(attachment, choice: choice) { return "Unavailable" }
        guard isActive(attachment, choice: choice) else { return "Play" }
        if isPlaying { return "Pause" }
        if isPaused { return "Resume" }
        return "Play"
    }

    func symbolName(for attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice? = nil) -> String {
        if isUnavailable(attachment, choice: choice) { return "exclamationmark.triangle.fill" }
        guard isActive(attachment, choice: choice) else { return "play.fill" }
        if isPlaying { return "pause.fill" }
        return "play.fill"
    }

    func isUnavailable(_ attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice? = nil) -> Bool {
        unavailablePlaybackID == playbackID(for: attachment, choice: choice ?? attachment.defaultPlaybackChoice)
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

    private func loadPlaybackSounds(
        for attachment: MeetingAudioAttachment,
        preferredChoice: MeetingAudioPlaybackChoice?
    ) -> (choice: MeetingAudioPlaybackChoice, sounds: [NSSound])? {
        for choice in MeetingAudioPlaybackLoadingPolicy.choices(for: attachment, preferredChoice: preferredChoice) {
            let loadedSounds = choice.urls.compactMap { url in
                NSSound(contentsOf: url, byReference: true)
            }
            if loadedSounds.count == choice.urls.count, !loadedSounds.isEmpty {
                return (choice, loadedSounds)
            }
        }

        return nil
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

    private func playbackID(for attachment: MeetingAudioAttachment, choice: MeetingAudioPlaybackChoice?) -> String {
        "\(attachment.id)#\(choice?.id ?? "default")"
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

enum MeetingAudioPlaybackLoadingPolicy {
    static func choices(
        for attachment: MeetingAudioAttachment,
        preferredChoice: MeetingAudioPlaybackChoice?
    ) -> [MeetingAudioPlaybackChoice] {
        let choices = attachment.playbackChoices
        guard let preferredChoice else {
            return choices.first.map { [$0] } ?? []
        }
        guard choices.contains(where: { $0.id == preferredChoice.id }) else {
            return choices.first.map { [$0] } ?? []
        }

        // Source-aware controls should not silently switch from System to Mic.
        // If the selected source cannot load, the user can choose another retained source.
        return [preferredChoice]
    }
}

struct MeetingAudioSourceMenu: View {
    let attachment: MeetingAudioAttachment
    @Binding var selectedChoiceID: String?
    var onSelect: (MeetingAudioPlaybackChoice) -> Void = { _ in }

    private var choices: [MeetingAudioPlaybackChoice] {
        attachment.playbackChoices
    }

    private var selectedChoice: MeetingAudioPlaybackChoice? {
        attachment.playbackChoice(id: selectedChoiceID)
    }

    var body: some View {
        if choices.count > 1, let selectedChoice {
            Menu {
                ForEach(choices) { choice in
                    Button {
                        selectedChoiceID = choice.id
                        onSelect(choice)
                    } label: {
                        Label(choice.title, systemImage: choice.id == selectedChoice.id ? "checkmark" : choice.symbolName)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: selectedChoice.symbolName)
                        .font(.system(size: 10, weight: .semibold))
                    Text(selectedChoice.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Choose retained meeting audio source")
        }
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

import AppKit
import Combine
import Foundation

@MainActor
final class MeetingAudioPlayback: NSObject, ObservableObject, NSSoundDelegate {
    static let shared = MeetingAudioPlayback()

    @Published private(set) var activeAttachmentID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var unavailableAttachmentID: String?

    private var sounds: [NSSound] = []

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

        let loadedSounds = attachment.urls.compactMap { url in
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
        isPlaying = true
        isPaused = false

        for sound in sounds {
            sound.delegate = self
            sound.play()
        }
    }

    func pause() {
        guard isPlaying else { return }
        for sound in sounds {
            sound.pause()
        }
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
    }

    func stop() {
        for sound in sounds {
            sound.stop()
            sound.delegate = nil
        }
        sounds.removeAll()
        activeAttachmentID = nil
        isPlaying = false
        isPaused = false
        unavailableAttachmentID = nil
    }

    func isActive(_ attachment: MeetingAudioAttachment) -> Bool {
        activeAttachmentID == attachment.id
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
}

import AVFoundation
import Foundation

enum UISoundPreferences {
    private static let enabledKey = "enableUISounds"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: enabledKey) != nil else { return true }
        return userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}

final class AppSoundPlayer {
    typealias WarningReporter = @Sendable (_ cue: Cue) -> Void

    enum Cue: CaseIterable {
        case dictationStart
        case dictationDelivered
        case dictationCancelled
        case noSpeech
        case meetingTranscriptComplete
        case feedbackSubmitted

        var bundledFileName: String? {
            switch self {
            case .dictationStart:
                return TranscriptedConstants.listeningStartSoundFileName
            case .dictationDelivered:
                return TranscriptedConstants.dictationDeliveredSoundFileName
            case .noSpeech:
                return TranscriptedConstants.dictationDeliveredSoundFileName
            case .meetingTranscriptComplete:
                return TranscriptedConstants.meetingTranscriptCompleteSoundFileName
            case .feedbackSubmitted:
                return TranscriptedConstants.feedbackSubmittedSoundFileName
            case .dictationCancelled:
                return nil
            }
        }

        var volumeMultiplier: Float {
            switch self {
            case .dictationDelivered, .noSpeech:
                return TranscriptedConstants.deliveredCueVolumeMultiplier
            case .dictationStart, .dictationCancelled, .meetingTranscriptComplete, .feedbackSubmitted:
                return 1.0
            }
        }
    }

    static let shared = AppSoundPlayer()

    private let queue = DispatchQueue(label: "com.transcripted.ui-sound-player", qos: .utility)
    private var players: [Cue: AVAudioPlayer] = [:]
    private var didAttemptPreload = false
    private var warningReporter: WarningReporter?

    private init() {}

    func setWarningReporter(_ reporter: WarningReporter?) {
        queue.async { [weak self] in
            self?.warningReporter = reporter
        }
    }

    func preload() {
        queue.async { [weak self] in
            self?.loadPlayersIfNeeded()
        }
    }

    func play(_ cue: Cue, respectingPreferences: Bool = true) {
        guard !respectingPreferences || UISoundPreferences.isEnabled() else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.loadPlayersIfNeeded()
            guard let player = self.players[cue] else { return }
            if player.isPlaying {
                player.stop()
            }
            player.currentTime = 0
            _ = player.play()
        }
    }

    private func loadPlayersIfNeeded() {
        guard !didAttemptPreload else { return }
        didAttemptPreload = true

        for cue in Cue.allCases {
            guard let url = Self.bundledURL(for: cue) else { continue }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = TranscriptedConstants.overlayCueVolume * cue.volumeMultiplier
                player.prepareToPlay()
                players[cue] = player
            } catch {
                warningReporter?(cue)
            }
        }
    }

    private static func bundledURL(for cue: Cue) -> URL? {
        guard let fileName = cue.bundledFileName else { return nil }
        return Bundle.main.resourceURL?.appendingPathComponent("Sounds/\(fileName)")
    }
}

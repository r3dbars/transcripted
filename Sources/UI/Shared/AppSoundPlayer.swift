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
        case dictationStop
        case dictationCancelled
        case noSpeech
        case meetingTranscriptComplete

        var bundledFileName: String? {
            switch self {
            case .dictationStart:
                return TranscriptedConstants.listeningStartSoundFileName
            case .dictationStop:
                return TranscriptedConstants.dictationStopSoundFileName
            case .noSpeech, .dictationCancelled:
                // Nothing was pasted, so these get their own soft drop.
                return TranscriptedConstants.dictationCancelledSoundFileName
            case .meetingTranscriptComplete:
                return TranscriptedConstants.meetingTranscriptCompleteSoundFileName
            }
        }

        var volumeMultiplier: Float {
            switch self {
            case .noSpeech:
                return TranscriptedConstants.noSpeechCueVolumeMultiplier
            case .dictationStart, .dictationStop, .dictationCancelled, .meetingTranscriptComplete:
                return 1.0
            }
        }
    }

    static let shared = AppSoundPlayer()

    // Output only; never opens an input device. userInitiated so a cue is not
    // starved behind background work while dictation is starting or stopping.
    private let queue = DispatchQueue(label: "com.transcripted.ui-sound-player", qos: .userInitiated)
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
        let requestedAt = ProcessInfo.processInfo.systemUptime
        queue.async { [weak self] in
            guard let self else { return }
            self.loadPlayersIfNeeded()
            // A click that lands a second late reads as a glitch, not feedback.
            guard !Self.isStale(requestedAt: requestedAt, now: ProcessInfo.processInfo.systemUptime) else { return }
            guard let player = self.players[cue] else { return }
            if player.isPlaying {
                player.stop()
            }
            player.currentTime = 0
            _ = player.play()
        }
    }

    static func isStale(requestedAt: TimeInterval, now: TimeInterval) -> Bool {
        now - requestedAt >= TranscriptedConstants.staleCueDropInterval
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

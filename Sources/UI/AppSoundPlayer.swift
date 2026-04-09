import AppKit

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

@MainActor
final class AppSoundPlayer {
    enum Cue: CaseIterable {
        case dictationStart
        case dictationDelivered
        case dictationCancelled
        case noSpeech
        case meetingTranscriptComplete

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
            case .dictationCancelled:
                return nil
            }
        }

        var fallbackSystemSoundName: String {
            switch self {
            case .dictationStart:
                return "Funk"
            case .dictationDelivered:
                return "Funk"
            case .dictationCancelled:
                return "Basso"
            case .noSpeech:
                return "Tink"
            case .meetingTranscriptComplete:
                return "Glass"
            }
        }

        var volumeMultiplier: Float {
            switch self {
            case .dictationDelivered, .noSpeech:
                return TranscriptedConstants.deliveredCueVolumeMultiplier
            case .dictationStart, .dictationCancelled, .meetingTranscriptComplete:
                return 1.0
            }
        }
    }

    static let shared = AppSoundPlayer()

    private let sounds: [Cue: NSSound]

    private init() {
        var loadedSounds: [Cue: NSSound] = [:]
        for cue in Cue.allCases {
            guard let sound = Self.loadSound(for: cue) else { continue }
            sound.volume = TranscriptedConstants.overlayCueVolume * cue.volumeMultiplier
            loadedSounds[cue] = sound
        }
        sounds = loadedSounds
    }

    func play(_ cue: Cue) {
        guard UISoundPreferences.isEnabled() else { return }
        guard let sound = sounds[cue] else { return }
        sound.stop()
        _ = sound.play()
    }

    private static func loadSound(for cue: Cue) -> NSSound? {
        if let fileName = cue.bundledFileName,
           let url = Bundle.main.resourceURL?.appendingPathComponent("Sounds/\(fileName)"),
           let sound = NSSound(contentsOf: url, byReference: true) {
            return sound
        }

        return NSSound(named: NSSound.Name(cue.fallbackSystemSoundName))
    }
}

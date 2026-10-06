import AVFoundation
import Foundation

enum UISoundPreferences {
    private static let enabledKey = "enableUISounds"
    /// macOS Settings > Sound > "Play user interface sound effects".
    private static let systemInterfaceSoundsKey = "com.apple.sound.uiaudio.enabled"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: enabledKey) != nil else { return true }
        return userDefaults.bool(forKey: enabledKey)
    }

    /// Unset means on, like macOS. UserDefaults.standard also reads the
    /// global domain, where macOS keeps this switch.
    static func systemInterfaceSoundsEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        guard let value = userDefaults.object(forKey: systemInterfaceSoundsKey) as? NSNumber else { return true }
        return value.boolValue
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}

protocol AppCueAudioPlayer: AnyObject {
    var volume: Float { get set }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func stop()
}

extension AVAudioPlayer: AppCueAudioPlayer {}

final class AppSoundPlayer {
    typealias WarningReporter = @Sendable (_ cue: Cue) -> Void

    enum Cue: CaseIterable {
        case dictationStart
        case dictationStop
        case dictationCancelled
        case noSpeech
        case meetingTranscriptComplete
        case meetingRecordingStart
        case meetingRecordingStop
        /// The menu bar menu's hover tick. Interface chrome, so it also
        /// follows the Mac's own interface-sounds switch.
        case menuHover
        /// A softer, lower tick for the rows under the buttons (Open
        /// Transcripted, Check for Updates, Quit).
        case menuRowHover
        /// A short, soft click when a menu bar button or row is pressed.
        case menuPress

        var bundledFileName: String? {
            switch self {
            case .dictationStart:
                return TranscriptedConstants.listeningStartSoundFileName
            case .dictationStop:
                return TranscriptedConstants.dictationStopSoundFileName
            case .noSpeech, .dictationCancelled:
                // Nothing was pasted, so these get their own double click.
                return TranscriptedConstants.dictationCancelledSoundFileName
            case .meetingTranscriptComplete:
                return TranscriptedConstants.meetingTranscriptCompleteSoundFileName
            case .meetingRecordingStart, .meetingRecordingStop:
                return nil
            case .menuHover:
                return "menu-hover.wav"
            case .menuRowHover:
                return "menu-row-hover.wav"
            case .menuPress:
                return "menu-press.wav"
            }
        }

        var volumeMultiplier: Float {
            switch self {
            case .dictationStart, .dictationStop:
                return TranscriptedConstants.dictationClickCueVolumeMultiplier
            case .noSpeech:
                return TranscriptedConstants.noSpeechCueVolumeMultiplier
            case .menuHover:
                // Barely there: 7% output, well under the dictation clicks.
                return 0.1
            case .menuRowHover:
                // Quieter still (about 5%), so the rows sit a tier below the buttons.
                return 0.07
            case .menuPress:
                // A touch firmer than the hover ticks (about 10%), still well
                // under the dictation clicks.
                return 0.15
            case .dictationCancelled, .meetingTranscriptComplete, .meetingRecordingStart, .meetingRecordingStop:
                return 1.0
            }
        }

        var followsSystemInterfaceSounds: Bool {
            switch self {
            case .menuHover, .menuRowHover, .menuPress:
                return true
            case .dictationStart, .dictationStop, .dictationCancelled, .noSpeech, .meetingTranscriptComplete,
                 .meetingRecordingStart, .meetingRecordingStop:
                return false
            }
        }

        var systemSoundFileName: String? {
            switch self {
            case .meetingRecordingStart: return "Tink.aiff"
            case .meetingRecordingStop: return "Pop.aiff"
            default: return nil
            }
        }

        var playbackVolume: Float {
            // Preserve the previous NSSound cues' default volume.
            systemSoundFileName == nil ? TranscriptedConstants.overlayCueVolume * volumeMultiplier : 1.0
        }
    }

    static let shared = AppSoundPlayer()

    // Output only; never opens an input device. userInitiated so a cue is not
    // starved behind background work while dictation is starting or stopping.
    private let queue: DispatchQueue
    private let makePlayer: (URL) throws -> AppCueAudioPlayer
    private let now: () -> TimeInterval
    private var players: [Cue: AppCueAudioPlayer] = [:]
    private var attemptedCues: Set<Cue> = []
    private var didAttemptPreload = false
    private var warningReporter: WarningReporter?

    init(
        queue: DispatchQueue = DispatchQueue(label: "com.transcripted.ui-sound-player", qos: .userInitiated),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        makePlayer: @escaping (URL) throws -> AppCueAudioPlayer = { try AVAudioPlayer(contentsOf: $0) }
    ) {
        self.queue = queue
        self.now = now
        self.makePlayer = makePlayer
    }

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
        guard !cue.followsSystemInterfaceSounds || UISoundPreferences.systemInterfaceSoundsEnabled() else { return }
        let requestedAt = now()
        queue.async { [weak self] in
            guard let self else { return }
            guard !Self.isStale(requestedAt: requestedAt, now: self.now()) else { return }
            self.loadPlayersIfNeeded()
            // A click that lands a second late reads as a glitch, not feedback.
            guard !Self.isStale(requestedAt: requestedAt, now: self.now()) else { return }
            guard let player = self.player(for: cue) else { return }
            // Creating or preparing a player can itself wait on Core Audio.
            guard !Self.isStale(requestedAt: requestedAt, now: self.now()) else { return }
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

        // Meeting system sounds stay lazy: launch preloading must not open
        // another native sound path before a meeting actually requests it.
        for cue in Cue.allCases where cue.systemSoundFileName == nil {
            _ = player(for: cue)
        }
    }

    private func player(for cue: Cue) -> AppCueAudioPlayer? {
        if let player = players[cue] { return player }
        guard attemptedCues.insert(cue).inserted, let url = Self.soundURL(for: cue) else { return nil }
        do {
            let player = try makePlayer(url)
            player.volume = cue.playbackVolume
            _ = player.prepareToPlay()
            players[cue] = player
            return player
        } catch {
            warningReporter?(cue)
            return nil
        }
    }

    static func soundURL(for cue: Cue) -> URL? {
        if let fileName = cue.systemSoundFileName {
            return URL(fileURLWithPath: "/System/Library/Sounds").appendingPathComponent(fileName)
        }
        guard let fileName = cue.bundledFileName else { return nil }
        return Bundle.main.resourceURL?.appendingPathComponent("Sounds/\(fileName)")
    }
}

import Foundation

struct MeetingAudioInactivityWarning: Equatable {
    enum Kind: String, Equatable {
        case noAudio = "no_audio"
        case degradedRoute = "degraded_route"
    }

    let inactiveDuration: TimeInterval
    let countdownSeconds: Int
    let kind: Kind
    let automaticStopAllowed: Bool

    init(
        inactiveDuration: TimeInterval,
        countdownSeconds: Int,
        kind: Kind = .noAudio,
        automaticStopAllowed: Bool = true
    ) {
        self.inactiveDuration = inactiveDuration
        self.countdownSeconds = countdownSeconds
        self.kind = kind
        self.automaticStopAllowed = automaticStopAllowed
    }
}

struct MeetingAudioInactivityDetector {
    struct Configuration: Equatable {
        let inactivityInterval: TimeInterval
        let countdownSeconds: Int
        let activeLevelThreshold: Float

        static let `default` = Configuration(
            inactivityInterval: 5 * 60,
            countdownSeconds: 30,
            activeLevelThreshold: 0.02
        )
    }

    enum Event: Equatable {
        case none
        case warningStarted(MeetingAudioInactivityWarning)
        case warningCleared
    }

    private let configuration: Configuration
    private var lastActivityTime: TimeInterval?
    private var snoozedUntilAudioActivity = false
    private(set) var warning: MeetingAudioInactivityWarning?

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    mutating func startRecording(at time: TimeInterval = 0) -> Event {
        lastActivityTime = max(0, time)
        snoozedUntilAudioActivity = false
        let hadWarning = warning != nil
        warning = nil
        return hadWarning ? .warningCleared : .none
    }

    mutating func stopRecording() -> Event {
        lastActivityTime = nil
        snoozedUntilAudioActivity = false
        let hadWarning = warning != nil
        warning = nil
        return hadWarning ? .warningCleared : .none
    }

    mutating func observe(micLevel: Float, systemLevel: Float, at time: TimeInterval) -> Event {
        let normalizedTime = max(0, time)

        if micLevel > configuration.activeLevelThreshold || systemLevel > configuration.activeLevelThreshold {
            lastActivityTime = normalizedTime
            snoozedUntilAudioActivity = false
            let hadWarning = warning != nil
            warning = nil
            return hadWarning ? .warningCleared : .none
        }

        return tick(at: normalizedTime)
    }

    mutating func tick(at time: TimeInterval) -> Event {
        let normalizedTime = max(0, time)

        guard let lastActivityTime else {
            self.lastActivityTime = normalizedTime
            return .none
        }

        if normalizedTime < lastActivityTime {
            self.lastActivityTime = normalizedTime
            return .none
        }

        guard warning == nil, !snoozedUntilAudioActivity else { return .none }

        let inactiveDuration = normalizedTime - lastActivityTime
        guard inactiveDuration >= configuration.inactivityInterval else { return .none }

        let warning = MeetingAudioInactivityWarning(
            inactiveDuration: inactiveDuration,
            countdownSeconds: configuration.countdownSeconds
        )
        self.warning = warning
        return .warningStarted(warning)
    }

    mutating func dismissWarning() -> Event {
        guard warning != nil else { return .none }
        warning = nil
        snoozedUntilAudioActivity = true
        return .warningCleared
    }
}

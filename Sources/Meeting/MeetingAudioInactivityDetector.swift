import Foundation

struct MeetingAudioInactivityWarning: Equatable {
    enum Kind: String, Equatable {
        case noAudio = "no_audio"
        case degradedRoute = "degraded_route"
        case callEnded = "call_ended"
    }

    let inactiveDuration: TimeInterval
    let countdownSeconds: Int
    let kind: Kind
    let automaticStopAllowed: Bool
    let recordingIdentity: UUID?

    init(
        inactiveDuration: TimeInterval,
        countdownSeconds: Int,
        kind: Kind = .noAudio,
        automaticStopAllowed: Bool = true,
        recordingIdentity: UUID? = nil
    ) {
        self.inactiveDuration = inactiveDuration
        self.countdownSeconds = countdownSeconds
        self.kind = kind
        self.automaticStopAllowed = automaticStopAllowed
        self.recordingIdentity = recordingIdentity
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

/// Call ownership changes independently of the waveform. The underlying
/// silence detector keeps observing so its warning can be restored later.
enum MeetingRecordingWarningOwner {
    /// A live call-end countdown wins: the user is deciding whether the
    /// meeting ended. Once that prompt is held (room audio or a failed
    /// read blocked the automatic stop), a silence warning that is already
    /// latched or arrives later takes over so a forgotten recording still
    /// ends.
    static func displayed(callEnd: MeetingAudioInactivityWarning?,
                          silence: MeetingAudioInactivityWarning?) -> MeetingAudioInactivityWarning? {
        if let callEnd, callEnd.kind == .callEnded {
            if !callEnd.automaticStopAllowed, let silence, silence.kind != .callEnded {
                return silence
            }
            return callEnd
        }
        return silence
    }

    /// After the call-end countdown is held, re-raise any silence warning
    /// the detector already latched. `tick` will not emit again while that
    /// warning is still stored, so a quiet call that crossed five minutes
    /// during the live countdown would otherwise sit on a held prompt
    /// forever.
    static func afterCallEndHeld(
        held: MeetingAudioInactivityWarning,
        pendingSilence: MeetingAudioInactivityWarning?
    ) -> MeetingAudioInactivityWarning {
        displayed(callEnd: held, silence: pendingSilence) ?? held
    }
}

import Foundation

/// Watches a live process tap that delivers only digital zeros while another
/// app is playing audio. Buffers still arrive, so the stall check never fires,
/// yet the other side of the call is lost.
///
/// Zeros alone are normal (an in-person meeting on a quiet Mac), so nothing
/// happens unless another process is running audio output. Then the tap is
/// rebuilt a bounded number of times, and if it still hears nothing while the
/// other app keeps playing, the watch reports it once so the host can tell
/// the user during the meeting.
///
/// Armed at start, after a wake, after any other rebuild, and when the Mac's
/// default output changes. It ends as soon as the tap hears any real signal.
/// Pure value type; the capture owns it on its serial queue.
struct SystemAudioSilenceWatch: Equatable {
    enum Reason: String {
        case start
        /// After a wake the tap has come back attached but silent (seen with
        /// AirPods as the output).
        case wake
        /// A format change, stall or other reconnect built a new tap.
        case rebuild
        /// The Mac's default output device changed.
        case outputChange
    }

    enum Action: Equatable {
        case none
        /// Rebuild the tap; the watch keeps its remaining budget.
        case reconnect
        /// Reconnects are spent and the tap has heard nothing for
        /// `unheardReportSeconds` while other audio kept playing.
        case reportUnheard
    }

    let reason: Reason
    /// End of the watch window. Nil watches until the tap hears signal.
    let until: TimeInterval?
    let silenceSeconds: TimeInterval
    private(set) var reconnectsLeft: Int
    private(set) var silentSince: TimeInterval?
    private(set) var lastPlaybackCheck: TimeInterval?
    /// First check, after the reconnects were spent, that found other audio
    /// playing and the tap still silent. Reset when playback stops.
    private(set) var unheardSince: TimeInterval?
    /// Reconnects are spent and other audio was playing: the rebuilds did
    /// not help.
    private(set) var exhausted = false
    private(set) var reportedUnheard = false

    /// How long after a wake a silent tap is still suspect.
    static let wakeWindowSeconds: TimeInterval = 300
    /// Digital silence this long after a wake, while another app plays,
    /// means the tap is not hearing the output.
    static let wakeSilenceSeconds: TimeInterval = 3
    /// One fresh tap per wake. A call app keeps its output running while the
    /// far end is quiet, so a rebuilt tap that still hears zeros is most
    /// likely a quiet call, and more rebuilds only cut real audio.
    static let maxWakeReconnects = 1
    /// At start and after other rebuilds there is no sign the tap is broken,
    /// so wait a little longer and rebuild once: the zeros being replaced
    /// are already lost, so a rebuild costs nothing that was heard.
    static let silenceSeconds: TimeInterval = 5
    static let maxReconnects = 1
    /// Silent-while-playing time after the last rebuild before the user is
    /// told. Long enough that most lobbies and pauses don't trip it; the ones
    /// that do are cleared as a false alarm when the same tap hears signal.
    static let unheardReportSeconds: TimeInterval = 60
    static let playbackCheckInterval: TimeInterval = 1

    static func armed(_ reason: Reason, at now: TimeInterval) -> SystemAudioSilenceWatch {
        switch reason {
        case .wake:
            return SystemAudioSilenceWatch(
                reason: reason,
                until: now + wakeWindowSeconds,
                silenceSeconds: wakeSilenceSeconds,
                reconnectsLeft: maxWakeReconnects
            )
        case .start, .rebuild, .outputChange:
            return SystemAudioSilenceWatch(
                reason: reason,
                until: nil,
                silenceSeconds: silenceSeconds,
                reconnectsLeft: maxReconnects
            )
        }
    }

    private init(reason: Reason, until: TimeInterval?, silenceSeconds: TimeInterval, reconnectsLeft: Int) {
        self.reason = reason
        self.until = until
        self.silenceSeconds = silenceSeconds
        self.reconnectsLeft = reconnectsLeft
    }

    /// Notes a delivered buffer. Returns false when the tap heard real
    /// signal: the watch is over.
    mutating func noteBuffer(hasSignal: Bool, at now: TimeInterval) -> Bool {
        guard !hasSignal else { return false }
        if silentSince == nil { silentSince = now }
        return true
    }

    /// A rebuilt tap gets a fresh silence window. The budget and the
    /// unheard clock carry over, so a rebuild never re-arms reconnects.
    mutating func restartSilence() {
        silentSince = nil
        lastPlaybackCheck = nil
    }

    /// A watch that already told the user never expires: it must stay to
    /// see signal return, or the warning would outlive a quiet call.
    func isExpired(at now: TimeInterval) -> Bool {
        guard let until, !reportedUnheard else { return false }
        return now >= until
    }

    /// True when `evaluate` would look at playback now. Lets the caller
    /// skip the process scan on every other tick.
    func wantsPlaybackCheck(at now: TimeInterval) -> Bool {
        guard let silentSince, now - silentSince >= silenceSeconds else { return false }
        if let lastPlaybackCheck, now - lastPlaybackCheck < Self.playbackCheckInterval { return false }
        return !reportedUnheard || reconnectsLeft > 0
    }

    mutating func evaluate(otherAudioPlaying: Bool, at now: TimeInterval) -> Action {
        guard wantsPlaybackCheck(at: now) else { return .none }
        lastPlaybackCheck = now
        guard otherAudioPlaying else {
            unheardSince = nil
            return .none
        }
        if reconnectsLeft > 0 {
            reconnectsLeft -= 1
            restartSilence()
            return .reconnect
        }
        exhausted = true
        let since = unheardSince ?? now
        unheardSince = since
        guard !reportedUnheard, now - since >= Self.unheardReportSeconds else { return .none }
        reportedUnheard = true
        return .reportUnheard
    }
}

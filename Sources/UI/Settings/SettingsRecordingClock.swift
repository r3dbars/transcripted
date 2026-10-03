import Combine
import Foundation
import Observation

/// The live recording time for Home's working row. The meeting session
/// publishes its duration several times a second; this keeps whole seconds
/// only, so just the elapsed label redraws once a second instead of the
/// whole Settings window.
@Observable
@MainActor
final class SettingsRecordingClock {
    private(set) var wholeSeconds = 0
    @ObservationIgnored private var subscription: AnyCancellable?

    init<Durations: Publisher>(durations: Durations)
    where Durations.Output == TimeInterval, Durations.Failure == Never {
        subscription = durations
            .wholeSecondTicks()
            .sink { [weak self] seconds in
                self?.wholeSeconds = seconds
            }
    }

    var elapsedText: String {
        HomeRecordingElapsed.text(TimeInterval(wholeSeconds))
    }
}

/// "m:ss", or "h:mm:ss" past an hour, for Home's recording row.
enum HomeRecordingElapsed {
    static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

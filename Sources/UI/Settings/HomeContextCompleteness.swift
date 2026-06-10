import Foundation

/// Pure scoring model behind the sidebar context ring.
///
/// The ring answers "how complete is the context my agent can read?" with three
/// weighted components: recent capture momentum, named speakers, and a
/// connected agent. Weights are product decisions, not measurements; keep them
/// here so the ring view and the stats sheet agree.
struct HomeContextCompleteness: Equatable {
    struct Segment: Equatable, Identifiable {
        let id: String
        /// Fraction of the full circle this segment fills (already weighted).
        let fraction: Double
    }

    /// Each component is 0...1 before weighting.
    let captureScore: Double
    let speakerScore: Double
    let agentScore: Double

    static let captureWeight = 0.4
    static let speakerWeight = 0.3
    static let agentWeight = 0.3

    /// Capturing on this many of the last 7 days counts as full capture momentum.
    static let fullCaptureDayTarget = 5

    var totalFraction: Double {
        captureScore * Self.captureWeight
            + speakerScore * Self.speakerWeight
            + agentScore * Self.agentWeight
    }

    var percentText: String {
        "\(Int((totalFraction * 100).rounded()))%"
    }

    /// Weighted arc fractions in display order. Zero-fraction segments are dropped
    /// so the ring never renders empty rounded caps.
    var segments: [Segment] {
        [
            Segment(id: "capture", fraction: captureScore * Self.captureWeight),
            Segment(id: "speakers", fraction: speakerScore * Self.speakerWeight),
            Segment(id: "agent", fraction: agentScore * Self.agentWeight)
        ].filter { $0.fraction > 0.0005 }
    }

    static func make(
        activeDaysInLastWeek: Int,
        namedSpeakerCount: Int,
        totalSpeakerCount: Int,
        agentConnected: Bool
    ) -> HomeContextCompleteness {
        let capture = min(1, max(0, Double(activeDaysInLastWeek)) / Double(fullCaptureDayTarget))
        let speakers: Double
        if totalSpeakerCount <= 0 {
            speakers = 0
        } else {
            speakers = min(1, max(0, Double(namedSpeakerCount) / Double(totalSpeakerCount)))
        }
        return HomeContextCompleteness(
            captureScore: capture,
            speakerScore: speakers,
            agentScore: agentConnected ? 1 : 0
        )
    }

    /// Counts distinct calendar days with activity inside the trailing 7-day window.
    static func activeDayCount(
        dayDates: [Date],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        guard let windowStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) else {
            return 0
        }
        let endOfToday = calendar.startOfDay(for: now).addingTimeInterval(60 * 60 * 24)
        let activeDays = Set(
            dayDates
                .filter { $0 >= windowStart && $0 < endOfToday }
                .map { calendar.startOfDay(for: $0) }
        )
        return activeDays.count
    }
}

/// Time-of-day greeting for the Home canvas header.
enum HomeCanvasGreeting {
    static func text(hour: Int, firstName: String) -> String {
        let salutation: String
        switch hour {
        case 5..<12:
            salutation = "Good morning"
        case 12..<17:
            salutation = "Good afternoon"
        default:
            salutation = "Good evening"
        }
        let trimmed = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return salutation }
        return "\(salutation), \(trimmed)"
    }
}

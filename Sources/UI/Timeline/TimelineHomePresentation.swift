import Foundation
import CoreGraphics

enum TimelineHomePreviewFlag {
    static let userDefaultsKey = "timeline-home-preview-enabled"
    static let environmentKey = "TRANSCRIPTED_TIMELINE_HOME_PREVIEW"

    static func isEnabled(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let rawValue = environment[environmentKey] {
            let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "on"].contains(normalized)
        }
        return userDefaults.bool(forKey: userDefaultsKey)
    }
}

enum TimelineCardKind: String, CaseIterable {
    case activity
    case meeting
    case dictation
    case idle

    var label: String {
        switch self {
        case .activity: return "Activity"
        case .meeting: return "Meeting"
        case .dictation: return "Dictation"
        case .idle: return "Idle"
        }
    }

    var symbolName: String {
        switch self {
        case .activity: return "rectangle.stack.fill"
        case .meeting: return "waveform"
        case .dictation: return "mic.fill"
        case .idle: return "moon.zzz.fill"
        }
    }
}

enum TimelineCategory: String, CaseIterable {
    case work = "Work"
    case meetings = "Meetings"
    case personal = "Personal"
    case distraction = "Distraction"
    case idle = "Idle"
}

struct TimelineCardPresentation: Identifiable, Equatable {
    let id: String
    let kind: TimelineCardKind
    let category: TimelineCategory
    let start: Date
    let end: Date
    let title: String
    let summary: String
    let detail: String
    let appSites: [String]
    let decisions: [String]

    var duration: TimeInterval {
        max(0, end.timeIntervalSince(start))
    }

    var durationMinutes: Int {
        max(1, Int((duration / 60).rounded()))
    }
}

struct TimelineCanvasLayout: Equatable {
    let dayStart: Date
    let dayEnd: Date
    let pixelsPerHour: CGFloat
    let minimumCardHeight: CGFloat
    let gap: CGFloat

    init(
        day: Date,
        calendar: Calendar = .current,
        pixelsPerHour: CGFloat = 60,
        minimumCardHeight: CGFloat = 18,
        gap: CGFloat = 2
    ) {
        let startOfDay = calendar.startOfDay(for: day)
        self.dayStart = calendar.date(byAdding: .hour, value: 4, to: startOfDay) ?? startOfDay
        self.dayEnd = calendar.date(byAdding: .hour, value: 24, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        self.pixelsPerHour = pixelsPerHour
        self.minimumCardHeight = minimumCardHeight
        self.gap = gap
    }

    var height: CGFloat {
        CGFloat(dayEnd.timeIntervalSince(dayStart) / 3_600) * pixelsPerHour
    }

    func yOffset(for date: Date) -> CGFloat {
        let clamped = min(max(date.timeIntervalSince(dayStart), 0), dayEnd.timeIntervalSince(dayStart))
        return CGFloat(clamped / 3_600) * pixelsPerHour
    }

    func height(for card: TimelineCardPresentation) -> CGFloat {
        let rawHeight = CGFloat(card.duration / 3_600) * pixelsPerHour
        return max(minimumCardHeight, rawHeight - gap)
    }
}

enum TimelineHomeSampleData {
    static func cards(now: Date = Date(), calendar: Calendar = .current) -> [TimelineCardPresentation] {
        let startOfToday = calendar.startOfDay(for: now)
        let base = calendar.date(byAdding: .hour, value: 8, to: startOfToday) ?? startOfToday
        let cards = [
            card(
                id: "planning",
                kind: .activity,
                category: .work,
                start: base.addingTimeInterval(18 * 60),
                minutes: 54,
                title: "Product planning",
                summary: "Shaped the timeline rollout and trimmed the risky backend work out of this pass.",
                detail: "The useful thread was keeping screenshots, meetings, and dictations in one readable day without making capture feel heavy.",
                appSites: ["Notes", "GitHub"],
                decisions: ["Keep Phase 4 UI-only", "Gate the new home behind preview flag"]
            ),
            card(
                id: "meeting",
                kind: .meeting,
                category: .meetings,
                start: base.addingTimeInterval(92 * 60),
                minutes: 38,
                title: "Timeline design review",
                summary: "Reviewed the first home canvas and agreed the detail panel should stay quiet until a card is selected.",
                detail: "Meeting card is inline with activity instead of a separate recent-meetings section, so it still feels like one day.",
                appSites: ["Transcripted"],
                decisions: ["Use compact cards", "Avoid nested panels"]
            ),
            card(
                id: "dictation",
                kind: .dictation,
                category: .meetings,
                start: base.addingTimeInterval(148 * 60),
                minutes: 14,
                title: "Captured follow-up",
                summary: "Dictated the acceptance notes for the mock timeline card states.",
                detail: "Short artifact cards should be visible but not dominate the canvas.",
                appSites: ["Transcripted"],
                decisions: ["Show dictations as thin blocks"]
            ),
            card(
                id: "build",
                kind: .activity,
                category: .work,
                start: base.addingTimeInterval(182 * 60),
                minutes: 72,
                title: "SwiftUI implementation",
                summary: "Built the preview-only home surface with sample timeline cards and pinned layout policy.",
                detail: "The UI reads as Transcripted: calm density, small controls, restrained color, and one selected detail area.",
                appSites: ["Xcode", "Terminal"],
                decisions: ["Use sample data until backend lands", "Pin canvas scale at 60 px per hour"]
            ),
            card(
                id: "idle",
                kind: .idle,
                category: .idle,
                start: base.addingTimeInterval(268 * 60),
                minutes: 26,
                title: "Away",
                summary: "No meaningful activity captured.",
                detail: "Idle cards stay quiet so real work and Transcripted artifacts carry the day.",
                appSites: [],
                decisions: []
            )
        ]

        return cards.sorted { $0.start < $1.start }
    }

    private static func card(
        id: String,
        kind: TimelineCardKind,
        category: TimelineCategory,
        start: Date,
        minutes: Int,
        title: String,
        summary: String,
        detail: String,
        appSites: [String],
        decisions: [String]
    ) -> TimelineCardPresentation {
        TimelineCardPresentation(
            id: id,
            kind: kind,
            category: category,
            start: start,
            end: start.addingTimeInterval(TimeInterval(minutes * 60)),
            title: title,
            summary: summary,
            detail: detail,
            appSites: appSites,
            decisions: decisions
        )
    }
}

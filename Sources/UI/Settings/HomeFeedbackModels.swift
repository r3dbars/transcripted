import SwiftUI
import TranscriptedCore

enum HomeFeedbackIssueKind: String, CaseIterable, Identifiable {
    case wrongWords
    case missingText
    case badFormatting
    case wrongSpeakers
    case audioProblem
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wrongWords: return "Wrong words"
        case .missingText: return "Missing text"
        case .badFormatting: return "Bad formatting"
        case .wrongSpeakers: return "Speaker issue"
        case .audioProblem: return "Audio issue"
        case .other: return "Other"
        }
    }
}

struct HomeFeedbackTarget: Identifiable {
    let id: String
    let sourceKind: String
    let title: String
    let createdAt: Date
    let referenceID: String
    let suggestedIssue: HomeFeedbackIssueKind

    static func dictation(_ entry: SavedDictationEntry) -> HomeFeedbackTarget {
        HomeFeedbackTarget(
            id: "dictation-\(stableReferenceID(for: entry.id))",
            sourceKind: "dictation",
            title: "Dictation at \(HomeActivityRowFormatting.timeFormatter.string(from: entry.createdAt))",
            createdAt: entry.createdAt,
            referenceID: stableReferenceID(for: entry.id),
            suggestedIssue: .wrongWords
        )
    }

    static func meeting(_ item: RecentMeetingItem) -> HomeFeedbackTarget {
        HomeFeedbackTarget(
            id: "meeting-\(stableReferenceID(for: item.id))",
            sourceKind: "meeting",
            title: "Meeting at \(HomeActivityRowFormatting.timeFormatter.string(from: item.date))",
            createdAt: item.date,
            referenceID: stableReferenceID(for: item.id),
            suggestedIssue: .wrongSpeakers
        )
    }

    private static func stableReferenceID(for value: String) -> String {
        HomeStableReferenceID.id(for: value)
    }
}

struct HomeFeedbackSubmission {
    let target: HomeFeedbackTarget
    let issueKind: HomeFeedbackIssueKind
    let notes: String
    let includeDiagnostics: Bool
}

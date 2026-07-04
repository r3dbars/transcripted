import Foundation

struct TimelineCategoryStore {
    static let defaults: [TimelineCategoryDescriptor] = [
        TimelineCategoryDescriptor(
            id: "work",
            name: "Work",
            colorHex: "#B984FF",
            details: "Focused work, planning, debugging, writing, and execution.",
            order: 0,
            isSystem: false,
            isIdle: false
        ),
        TimelineCategoryDescriptor(
            id: "personal",
            name: "Personal",
            colorHex: "#6AADFF",
            details: "Personal tasks, errands, learning, or non-work activity.",
            order: 1,
            isSystem: false,
            isIdle: false
        ),
        TimelineCategoryDescriptor(
            id: "distraction",
            name: "Distraction",
            colorHex: "#FF5950",
            details: "Unrelated interruptions that changed intent.",
            order: 2,
            isSystem: false,
            isIdle: false
        ),
        TimelineCategoryDescriptor(
            id: "idle",
            name: "Idle",
            colorHex: "#A0AEC0",
            details: "The Mac was idle for most of this window.",
            order: 3,
            isSystem: true,
            isIdle: true
        ),
        TimelineCategoryDescriptor(
            id: "meetings",
            name: "Meetings",
            colorHex: "#2DD4BF",
            details: "Transcripted meetings and spoken capture.",
            order: 4,
            isSystem: true,
            isIdle: false
        )
    ]

    var categories: [TimelineCategoryDescriptor]

    init(categories: [TimelineCategoryDescriptor] = TimelineCategoryStore.defaults) {
        self.categories = categories.sorted { $0.order < $1.order }
    }

    func descriptorsForLLM() -> String {
        categories
            .sorted { $0.order < $1.order }
            .map { "\($0.name): \($0.details)" }
            .joined(separator: "\n")
    }

    func normalizedName(for proposedName: String) -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = categories.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return match.name
        }
        return categories.first?.name ?? trimmed
    }

    func idleCategoryName() -> String {
        categories.first(where: { $0.isIdle })?.name ?? "Idle"
    }
}

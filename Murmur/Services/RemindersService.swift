import Foundation
import EventKit

/// Represents a Reminders list (calendar) for display in UI
struct RemindersList: Identifiable, Hashable {
    let id: String  // calendarIdentifier
    let title: String
    let color: CGColor?

    var isDefault: Bool = false
}

/// Service for creating reminders in Apple Reminders app
@available(macOS 14.0, *)
class RemindersService {
    private let store = EKEventStore()

    /// Request access to Reminders
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToReminders()
        } catch {
            AppLogger.services.warning("Reminders access error", ["error": error.localizedDescription])
            return false
        }
    }

    /// Fetch all available reminder lists
    func getRemindersLists() -> [RemindersList] {
        let calendars = store.calendars(for: .reminder)
        let defaultCalendar = store.defaultCalendarForNewReminders()

        return calendars.map { calendar in
            RemindersList(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                color: calendar.cgColor,
                isDefault: calendar.calendarIdentifier == defaultCalendar?.calendarIdentifier
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Get calendar by identifier, falling back to default if not found
    private func getCalendar(identifier: String?) -> EKCalendar? {
        if let id = identifier,
           let calendar = store.calendar(withIdentifier: id) {
            return calendar
        }
        return store.defaultCalendarForNewReminders()
    }

    /// Create a single reminder in the specified list
    func createReminder(title: String, notes: String?, dueDate: Date?, priority: Int, listId: String? = nil) throws {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.priority = priority

        if let date = dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: date
            )
        }

        // Use selected list or fall back to default
        reminder.calendar = getCalendar(identifier: listId)

        try store.save(reminder, commit: true)
    }

    /// Create reminders from extracted action items
    /// - Returns: TaskCreationResult with success/failure details (Phase 2 enhancement)
    func createReminders(from items: [ActionItem], listId: String? = nil) async -> TaskCreationResult {
        guard !items.isEmpty else {
            return .empty
        }

        // Use provided listId or fall back to user preference
        let targetListId = listId ?? UserDefaults.standard.string(forKey: "remindersListId")

        var successCount = 0
        var failures: [TaskCreationFailure] = []

        for item in items {
            do {
                // Map priority string to EventKit priority
                let priority = mapPriority(item.priority)

                // Parse due date if provided
                let dueDate = DateParser.parseNaturalDate(item.dueDate)

                // Build reminder title with owner prefix
                let title = item.owner.isEmpty || item.owner == "You"
                    ? item.task
                    : "[\(item.owner)] \(item.task)"

                try createReminder(
                    title: title,
                    notes: item.context,
                    dueDate: dueDate,
                    priority: priority,
                    listId: targetListId
                )

                successCount += 1
                AppLogger.services.info("Created reminder", ["title": title])

            } catch {
                let failure = TaskCreationFailure(
                    taskTitle: item.task,
                    errorMessage: error.localizedDescription,
                    isRecoverable: true,
                    recoveryHint: "Check Reminders permissions in System Settings"
                )
                failures.append(failure)
                AppLogger.services.warning("Failed to create reminder", ["task": item.task, "error": error.localizedDescription])
            }
        }

        return TaskCreationResult(
            successCount: successCount,
            failureCount: failures.count,
            failures: failures
        )
    }

    /// Map priority string to EventKit priority value
    /// - Note: EventKit uses 1 (highest) to 9 (lowest), 0 = none
    private func mapPriority(_ priority: String) -> Int {
        switch priority.lowercased() {
        case "high":
            return 1
        case "medium":
            return 5
        case "low":
            return 9
        default:
            return 0  // No priority
        }
    }
}

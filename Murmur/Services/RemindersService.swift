import Foundation
import EventKit

/// Service for creating reminders in Apple Reminders app
@available(macOS 14.0, *)
class RemindersService {
    private let store = EKEventStore()

    /// Request access to Reminders
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToReminders()
        } catch {
            print("⚠️ Reminders access error: \(error.localizedDescription)")
            return false
        }
    }

    /// Create a single reminder
    func createReminder(title: String, notes: String?, dueDate: Date?, priority: Int) throws {
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

        // Use default reminders list
        reminder.calendar = store.defaultCalendarForNewReminders()

        try store.save(reminder, commit: true)
    }

    /// Create reminders from extracted action items
    /// - Returns: TaskCreationResult with success/failure details (Phase 2 enhancement)
    func createReminders(from items: [ActionItem]) async -> TaskCreationResult {
        guard !items.isEmpty else {
            return .empty
        }

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
                    priority: priority
                )

                successCount += 1
                print("✓ Created reminder: \(title)")

            } catch {
                let failure = TaskCreationFailure(
                    taskTitle: item.task,
                    errorMessage: error.localizedDescription,
                    isRecoverable: true,
                    recoveryHint: "Check Reminders permissions in System Settings"
                )
                failures.append(failure)
                print("⚠️ Failed to create reminder for '\(item.task)': \(error.localizedDescription)")
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

import Foundation

/// Service for creating tasks in Todoist via REST API
@available(macOS 14.0, *)
class TodoistService {
    private let baseURL = "https://api.todoist.com/rest/v2"

    /// Validate API key by fetching projects (lightweight call)
    static func validateAPIKey(_ key: String) async -> Bool {
        guard !key.isEmpty else { return false }

        var request = URLRequest(url: URL(string: "https://api.todoist.com/rest/v2/projects")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Create a single task in Todoist Inbox
    func createTask(content: String, description: String?, dueString: String?, priority: Int) async throws {
        let apiKey = UserDefaults.standard.string(forKey: "todoistAPIKey") ?? ""
        guard !apiKey.isEmpty else { throw TodoistError.noAPIKey }

        var request = URLRequest(url: URL(string: "\(baseURL)/tasks")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build request body - limit description to 16K chars (Todoist limit)
        var body: [String: Any] = ["content": content, "priority": priority]
        if let desc = description, !desc.isEmpty {
            // Todoist has a 16,384 character limit on description
            let truncatedDesc = desc.count > 16000 ? String(desc.prefix(16000)) + "..." : desc
            body["description"] = truncatedDesc
        }
        // Sanitize due string - Todoist only accepts specific formats
        if let due = dueString, !due.isEmpty, let sanitized = sanitizeDueString(due) {
            body["due_string"] = sanitized
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TodoistError.requestFailed(statusCode: 0, message: "Invalid response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
            print("⚠️ Todoist API error \(httpResponse.statusCode): \(errorBody)")
            throw TodoistError.requestFailed(statusCode: httpResponse.statusCode, message: errorBody)
        }
    }

    /// Create tasks from action items, returns count of successfully created tasks
    func createTasks(from actionItems: [ActionItem]) async -> Int {
        var createdCount = 0

        for (index, item) in actionItems.enumerated() {
            let title = formatTitle(task: item.task, owner: item.owner)
            let priority = mapPriority(item.priority)

            do {
                try await createTask(
                    content: title,
                    description: item.context,
                    dueString: item.dueDate,
                    priority: priority
                )
                createdCount += 1
                print("✓ Created Todoist task: \(title)")
            } catch {
                print("❌ Failed to create Todoist task '\(title)': \(error)")
            }

            // Small delay between requests to avoid rate limiting (100ms)
            if index < actionItems.count - 1 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        return createdCount
    }

    /// Format title - label non-"You" tasks as follow-ups
    private func formatTitle(task: String, owner: String) -> String {
        let normalizedOwner = owner.lowercased()

        // Your tasks - no prefix
        if normalizedOwner == "you" || normalizedOwner == "me" || normalizedOwner.isEmpty {
            return task
        }

        // Others' tasks - prefix with "Follow-up:" and include owner
        return "Follow-up: [\(owner)] \(task)"
    }

    /// Map priority string to Todoist priority (1=normal, 4=urgent)
    private func mapPriority(_ priority: String) -> Int {
        switch priority.lowercased() {
        case "high": return 4    // Urgent
        case "medium": return 3
        case "low": return 2
        default: return 1        // Normal
        }
    }

    /// Sanitize due string to Todoist-compatible format
    /// Todoist accepts: "today", "tomorrow", "next week", "Monday", "Jan 15", "2024-01-15"
    /// Returns nil if date is too vague to convert
    private func sanitizeDueString(_ input: String) -> String? {
        let lowercased = input.lowercased().trimmingCharacters(in: .whitespaces)

        // Filter out null/none/empty values
        if lowercased == "null" || lowercased == "none" || lowercased == "n/a" || lowercased.isEmpty {
            return nil
        }

        // Already valid Todoist formats - pass through (but clean up extra words)
        if lowercased.contains("next week") {
            return "next week"
        }
        if lowercased.contains("next month") {
            return "next month"
        }
        if lowercased == "today" || lowercased == "tomorrow" {
            return lowercased
        }

        // Day names are valid
        let dayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        for day in dayNames {
            if lowercased.contains(day) {
                // Extract just "next Monday" or "Monday"
                if lowercased.contains("next") {
                    return "next \(day.capitalized)"
                }
                return day.capitalized
            }
        }

        // Common vague phrases → convert to concrete dates
        if lowercased.contains("couple") && lowercased.contains("week") {
            return "in 2 weeks"
        }
        if lowercased.contains("few") && lowercased.contains("week") {
            return "in 3 weeks"
        }
        if lowercased.contains("couple") && lowercased.contains("day") {
            return "in 2 days"
        }
        if lowercased.contains("few") && lowercased.contains("day") {
            return "in 3 days"
        }
        if lowercased.contains("end of week") || lowercased.contains("eow") {
            return "Friday"
        }
        if lowercased.contains("end of month") || lowercased.contains("eom") {
            return "last day of month"
        }
        if lowercased.contains("end of day") || lowercased.contains("eod") {
            return "today"
        }
        if lowercased.contains("asap") || lowercased.contains("as soon as") {
            return "today"
        }

        // Check for month names (e.g., "sometime in January" → "January")
        let monthNames = ["january", "february", "march", "april", "may", "june",
                          "july", "august", "september", "october", "november", "december"]
        for month in monthNames {
            if lowercased.contains(month) {
                // Try to extract a date like "January 15" or just use "January 1"
                return month.capitalized
            }
        }

        // If we can't parse it, skip the due date rather than fail
        print("⚠️ Skipping unparseable due date: '\(input)'")
        return nil
    }

    enum TodoistError: LocalizedError {
        case noAPIKey
        case requestFailed(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "Todoist API key not configured"
            case .requestFailed(let statusCode, let message):
                return "Todoist API error (\(statusCode)): \(message)"
            }
        }
    }
}

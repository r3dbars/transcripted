import Foundation

// MARK: - Task Creation Result Types (Phase 2)

/// Result type for task service operations (Reminders/Todoist)
/// Captures both successful and failed task creations
struct TaskCreationResult: Equatable {
    let successCount: Int
    let failureCount: Int
    let failures: [TaskCreationFailure]

    /// Total number of tasks attempted
    var totalAttempted: Int { successCount + failureCount }

    /// True if all tasks were created successfully
    var allSucceeded: Bool { failureCount == 0 && successCount > 0 }

    /// True if some tasks succeeded but others failed
    var partialSuccess: Bool { successCount > 0 && failureCount > 0 }

    /// True if all tasks failed
    var allFailed: Bool { successCount == 0 && failureCount > 0 }

    /// True if no tasks were attempted
    var isEmpty: Bool { totalAttempted == 0 }

    /// Human-readable summary for UI display
    var summary: String {
        if allSucceeded {
            return "\(successCount) task\(successCount == 1 ? "" : "s") added"
        } else if partialSuccess {
            return "\(successCount) added, \(failureCount) failed"
        } else if allFailed {
            return "Failed to add \(failureCount) task\(failureCount == 1 ? "" : "s")"
        } else {
            return "No tasks to add"
        }
    }

    /// Create a successful result with no failures
    static func success(count: Int) -> TaskCreationResult {
        TaskCreationResult(successCount: count, failureCount: 0, failures: [])
    }

    /// Create a failed result with no successes
    static func failed(failures: [TaskCreationFailure]) -> TaskCreationResult {
        TaskCreationResult(successCount: 0, failureCount: failures.count, failures: failures)
    }

    /// Create an empty result (no tasks attempted)
    static let empty = TaskCreationResult(successCount: 0, failureCount: 0, failures: [])
}

/// Represents a single task creation failure
struct TaskCreationFailure: Equatable, Identifiable {
    let id: UUID
    let taskTitle: String
    let errorMessage: String
    let isRecoverable: Bool
    let recoveryHint: String?

    init(taskTitle: String, errorMessage: String, isRecoverable: Bool = true, recoveryHint: String? = nil) {
        self.id = UUID()
        self.taskTitle = taskTitle
        self.errorMessage = errorMessage
        self.isRecoverable = isRecoverable
        self.recoveryHint = recoveryHint
    }

    static func == (lhs: TaskCreationFailure, rhs: TaskCreationFailure) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Action Item Extraction Errors

/// Specific error types for action item extraction via Gemini API
enum ActionItemExtractionError: LocalizedError {
    case noAPIKey
    case invalidAPIKey
    case networkError(underlying: Error)
    case apiError(statusCode: Int, message: String)
    case parseError(context: String)
    case timeout
    case rateLimited(retryAfter: TimeInterval?)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "Gemini API key not configured"
        case .invalidAPIKey:
            return "Invalid Gemini API key"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let code, let message):
            return "API error (\(code)): \(message)"
        case .parseError(let context):
            return "Failed to parse response: \(context)"
        case .timeout:
            return "Request timed out"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry in \(Int(seconds))s"
            }
            return "Rate limited. Please try again later"
        case .emptyTranscript:
            return "Transcript is empty"
        }
    }

    var recoveryHint: String {
        switch self {
        case .noAPIKey:
            return "Add your Gemini API key in Settings → AI Features"
        case .invalidAPIKey:
            return "Check your Gemini API key in Settings → AI Features"
        case .networkError:
            return "Check your internet connection and try again"
        case .apiError(let code, _):
            if code == 401 || code == 403 {
                return "Check your API key permissions"
            }
            return "Try again or check API status"
        case .parseError:
            return "Try again - this may be a temporary issue"
        case .timeout:
            return "Try again with a shorter recording"
        case .rateLimited:
            return "Wait a moment and try again"
        case .emptyTranscript:
            return "Record a conversation first"
        }
    }

    /// Whether this error is likely recoverable with a retry
    var isRecoverable: Bool {
        switch self {
        case .noAPIKey, .invalidAPIKey, .emptyTranscript:
            return false  // Needs user action, not just retry
        case .networkError, .timeout, .rateLimited, .parseError:
            return true   // Retry may help
        case .apiError(let code, _):
            return code >= 500 || code == 429  // Server errors and rate limits
        }
    }
}

// MARK: - Service Permission Errors

/// Errors related to service permissions
enum ServicePermissionError: LocalizedError {
    case remindersDenied
    case remindersRestricted
    case todoistNotConfigured
    case todoistInvalidKey

    var errorDescription: String? {
        switch self {
        case .remindersDenied:
            return "Reminders access denied"
        case .remindersRestricted:
            return "Reminders access restricted"
        case .todoistNotConfigured:
            return "Todoist not configured"
        case .todoistInvalidKey:
            return "Invalid Todoist API key"
        }
    }

    var recoveryHint: String {
        switch self {
        case .remindersDenied, .remindersRestricted:
            return "Enable Reminders access in System Settings → Privacy & Security → Reminders"
        case .todoistNotConfigured:
            return "Add your Todoist API key in Settings → AI Features"
        case .todoistInvalidKey:
            return "Check your Todoist API key in Settings → AI Features"
        }
    }
}

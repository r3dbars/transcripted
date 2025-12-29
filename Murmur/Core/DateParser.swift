import Foundation

/// Parses natural language date strings into Date objects
enum DateParser {
    /// Parse a natural language date string into a Date
    /// - Parameter string: Natural language date like "next Friday", "tomorrow", "end of week"
    /// - Returns: Parsed Date or nil if parsing fails
    static func parseNaturalDate(_ string: String?) -> Date? {
        guard let dateString = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dateString.isEmpty else {
            return nil
        }

        // Try NSDataDetector for natural language parsing
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(dateString.startIndex..., in: dateString)

        if let match = detector?.firstMatch(in: dateString, options: [], range: range),
           let date = match.date {
            return date
        }

        // Fallback: handle common relative phrases manually
        let lowercased = dateString.lowercased()
        let calendar = Calendar.current
        let now = Date()

        switch lowercased {
        case "today":
            return calendar.startOfDay(for: now)

        case "tomorrow":
            return calendar.date(byAdding: .day, value: 1, to: now)

        case "end of day", "eod":
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = 17
            return calendar.date(from: components)

        case "end of week", "eow":
            let weekday = calendar.component(.weekday, from: now)
            let daysUntilFriday = (6 - weekday + 7) % 7
            return calendar.date(byAdding: .day, value: daysUntilFriday == 0 ? 7 : daysUntilFriday, to: now)

        case "end of year", "eoy":
            var components = DateComponents()
            components.year = calendar.component(.year, from: now)
            components.month = 12
            components.day = 31
            return calendar.date(from: components)

        case "end of month", "eom":
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: now) else { return nil }
            let startOfNextMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: nextMonth))!
            return calendar.date(byAdding: .day, value: -1, to: startOfNextMonth)

        case "next week":
            return calendar.date(byAdding: .weekOfYear, value: 1, to: now)

        default:
            // Try parsing "in X days" pattern
            if lowercased.hasPrefix("in ") && lowercased.hasSuffix(" days") {
                let numberPart = lowercased.dropFirst(3).dropLast(5).trimmingCharacters(in: .whitespaces)
                if let days = Int(numberPart) {
                    return calendar.date(byAdding: .day, value: days, to: now)
                }
            }
            return nil
        }
    }
}

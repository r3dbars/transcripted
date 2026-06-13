import Foundation

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

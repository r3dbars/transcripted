import Foundation

enum DictationStopFinalizationOrder: String {
    case saveAfterAutoEnter
    case saveBeforeAutoEnter

    static func parse(_ value: String) -> DictationStopFinalizationOrder? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()

        switch normalized {
        case "saveafterautoenter", "save_after_auto_enter":
            return .saveAfterAutoEnter
        case "savebeforeautoenter", "save_before_auto_enter":
            return .saveBeforeAutoEnter
        default:
            return nil
        }
    }
}

enum DictationStopFinalizationPolicy {
    static let order: DictationStopFinalizationOrder = .saveBeforeAutoEnter
}

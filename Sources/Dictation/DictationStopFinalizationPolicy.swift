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

struct DictationStopFinalizationResult<AutoEnterOutcome, SaveResult> {
    let autoEnterOutcome: AutoEnterOutcome
    let saveResult: SaveResult
}

enum DictationStopFinalizer {
    @MainActor
    static func finalize<SaveResult, AutoEnterOutcome>(
        order: DictationStopFinalizationOrder,
        startSaving: () -> Task<SaveResult, Never>,
        finishSaving: (Task<SaveResult, Never>) async -> SaveResult,
        saveSynchronously: () -> SaveResult,
        performAutoEnter: () async -> AutoEnterOutcome
    ) async -> DictationStopFinalizationResult<AutoEnterOutcome, SaveResult> {
        switch order {
        case .saveAfterAutoEnter:
            let autoEnterOutcome = await performAutoEnter()
            let saveResult = saveSynchronously()
            return DictationStopFinalizationResult(
                autoEnterOutcome: autoEnterOutcome,
                saveResult: saveResult
            )
        case .saveBeforeAutoEnter:
            let saveTask = startSaving()
            let autoEnterOutcome = await performAutoEnter()
            let saveResult = await finishSaving(saveTask)
            return DictationStopFinalizationResult(
                autoEnterOutcome: autoEnterOutcome,
                saveResult: saveResult
            )
        }
    }
}

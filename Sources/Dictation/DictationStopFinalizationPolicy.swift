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

struct DictationStopFinalizationResult<AutoEnterOutcome, SaveFailure> {
    let autoEnterOutcome: AutoEnterOutcome
    let saveFailure: SaveFailure?
}

enum DictationStopFinalizer {
    @MainActor
    static func finalize<SaveValue, AutoEnterOutcome, SaveFailure>(
        order: DictationStopFinalizationOrder,
        startSaving: () -> Task<Result<SaveValue, Error>, Never>,
        finishSaving: (Task<Result<SaveValue, Error>, Never>) async -> SaveFailure?,
        saveSynchronously: () -> SaveFailure?,
        performAutoEnter: () async -> AutoEnterOutcome
    ) async -> DictationStopFinalizationResult<AutoEnterOutcome, SaveFailure> {
        switch order {
        case .saveAfterAutoEnter:
            let autoEnterOutcome = await performAutoEnter()
            let saveFailure = saveSynchronously()
            return DictationStopFinalizationResult(
                autoEnterOutcome: autoEnterOutcome,
                saveFailure: saveFailure
            )
        case .saveBeforeAutoEnter:
            let saveTask = startSaving()
            let autoEnterOutcome = await performAutoEnter()
            let saveFailure = await finishSaving(saveTask)
            return DictationStopFinalizationResult(
                autoEnterOutcome: autoEnterOutcome,
                saveFailure: saveFailure
            )
        }
    }
}

import Foundation

/// One keyboard action keeps its original admission through installation,
/// state refresh (which can select the keyboard), and an optional retry.
@MainActor
public enum WritingKeyboardActivationFlow {
    @discardableResult
    public static func start(
        prepare: @MainActor () -> Void = {},
        admission: @escaping @MainActor () -> Int?,
        attempt: @escaping @MainActor () async -> Bool,
        refresh: @escaping @MainActor () -> Void,
        retryWait: (@MainActor () async throws -> Void)? = nil
    ) -> Task<Void, Never> {
        // Setup intentionally applies its new runtime state first. Capture
        // synchronously, so a stop before the Task starts also invalidates it.
        prepare()
        let originalAdmission = admission()
        return Task { @MainActor in
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && originalAdmission != nil && admission() == originalAdmission
            }
            guard isCurrent() else { return }
            let selected = await attempt()
            guard isCurrent() else { return }
            refresh()
            guard !selected, let retryWait, isCurrent() else { return }
            do { try await retryWait() } catch { return }
            guard isCurrent() else { return }
            _ = await attempt()
            guard isCurrent() else { return }
            refresh()
        }
    }
}

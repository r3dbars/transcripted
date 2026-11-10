/// Routes Paste again from the text currently shown by the recent-take card.
/// Reads once before dismissing, so clearing the card cannot change its payload.
@MainActor
enum RecentDictationPasteAction {
    @discardableResult
    static func request(
        visibleText: @MainActor () -> String?,
        dismiss: @MainActor () -> Void,
        deliver: @MainActor (String) -> Void
    ) -> Bool {
        guard let text = visibleText(), !text.isEmpty else { return false }
        dismiss()
        deliver(text)
        return true
    }
}

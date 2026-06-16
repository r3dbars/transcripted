import SwiftUI
import AppKit
import TranscriptedCore

/// SwiftUI wrapper around the same `NSComboBox`-based autocomplete the
/// post-meeting speaker naming sheet uses (`SpeakerRowView`'s `nameField`).
/// It reuses `SpeakerNameSelectionPolicy` for label building, suggestion
/// ordering, and inline completion so the Speakers screen's "Who is this?"
/// field matches existing voices exactly the way naming does elsewhere.
struct SpeakerNameAutocompleteField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var options: [SpeakerIdentityOption]
    var accessibilityIdentifier: String?
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.isEditable = true
        combo.completes = true
        combo.usesDataSource = true
        combo.dataSource = context.coordinator
        combo.delegate = context.coordinator
        combo.font = NSFont.systemFont(ofSize: 13)
        combo.placeholderString = placeholder
        combo.stringValue = text
        if let accessibilityIdentifier {
            combo.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
            combo.setAccessibilityIdentifier(accessibilityIdentifier)
        }
        context.coordinator.rebuild(options: options)
        combo.numberOfVisibleItems = Self.visibleItemCount(for: options)
        return combo
    }

    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.parent = self
        context.coordinator.rebuild(options: options)
        if combo.stringValue != text {
            combo.stringValue = text
        }
        combo.placeholderString = placeholder
        combo.numberOfVisibleItems = Self.visibleItemCount(for: options)
    }

    private static func visibleItemCount(for options: [SpeakerIdentityOption]) -> Int {
        min(max(options.count, 4), 8)
    }

    final class Coordinator: NSObject, NSComboBoxDataSource, NSComboBoxDelegate {
        var parent: SpeakerNameAutocompleteField
        private var labels: [String] = []
        private var optionsByLabel: [String: SpeakerIdentityOption] = [:]

        init(_ parent: SpeakerNameAutocompleteField) {
            self.parent = parent
        }

        func rebuild(options: [SpeakerIdentityOption]) {
            let built = SpeakerNameSelectionPolicy.makeIdentityLabels(
                for: options,
                id: { $0.id },
                displayName: { $0.displayName },
                callCount: { $0.callCount }
            )
            labels = built.labels
            optionsByLabel = built.lookup
        }

        private func visibleLabels(for query: String) -> [String] {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return labels }
            return SpeakerNameSelectionPolicy.sortedLabels(
                matching: trimmed,
                labels: labels,
                optionsByLabel: optionsByLabel,
                displayName: { $0.displayName },
                callCount: { $0.callCount }
            )
        }

        // MARK: NSComboBoxDataSource

        func numberOfItems(in comboBox: NSComboBox) -> Int {
            visibleLabels(for: comboBox.stringValue).count
        }

        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            let visible = visibleLabels(for: comboBox.stringValue)
            guard visible.indices.contains(index) else { return nil }
            return visible[index]
        }

        func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
            SpeakerNameSelectionPolicy.completedLabel(
                for: string,
                labels: labels,
                optionsByLabel: optionsByLabel,
                displayName: { $0.displayName },
                callCount: { $0.callCount }
            )
        }

        func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
            visibleLabels(for: comboBox.stringValue).firstIndex(of: string) ?? NSNotFound
        }

        // MARK: NSComboBoxDelegate

        func controlTextDidChange(_ obj: Notification) {
            guard let combo = obj.object as? NSComboBox else { return }
            parent.text = combo.stringValue
            combo.reloadData()
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            // Resolve on the next runloop tick: at notification time the combo's
            // selected index is set but `objectValueOfSelectedItem` is not yet
            // committed to the field.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let index = combo.indexOfSelectedItem
                let visible = self.visibleLabels(for: combo.stringValue)
                guard visible.indices.contains(index) else { return }
                let label = visible[index]
                // Map the (possibly decorated) dropdown label back to the plain
                // display name, matching what the naming sheet stores.
                let resolved = SpeakerNameSelectionPolicy.option(
                    matching: label,
                    optionsByLabel: self.optionsByLabel,
                    displayName: { $0.displayName }
                )?.displayName ?? label
                combo.stringValue = resolved
                self.parent.text = resolved
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard let combo = control as? NSComboBox else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = combo.stringValue
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

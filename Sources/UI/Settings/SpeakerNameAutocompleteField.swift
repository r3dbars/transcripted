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
    /// Carries the exact saved-person UUID selected from the dropdown. Typing
    /// clears it, so callers can distinguish a new name from choosing one of
    /// two saved people who happen to share the same display name.
    var selectedOptionID: Binding<UUID?>? = nil
    /// When a picker opens prefilled with the current transcript label, its
    /// disclosure tray should show every saved person instead of treating that
    /// old label as an active search query.
    var showAllWhenTextEquals: String? = nil
    var accessibilityIdentifier: String?
    var autoFocus = false
    var onSubmit: () -> Void
    var onCancel: (() -> Void)? = nil

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
        if autoFocus {
            DispatchQueue.main.async {
                guard combo.window != nil else { return }
                combo.window?.makeFirstResponder(combo)
            }
        }
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
            if let initial = parent.showAllWhenTextEquals,
               SpeakerNameSelectionPolicy.normalizedSearchText(trimmed)
                == SpeakerNameSelectionPolicy.normalizedSearchText(initial) {
                return labels
            }
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
            parent.selectedOptionID?.wrappedValue = nil
            combo.reloadData()
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            // Resolve the picked label *now*, while `stringValue` still holds the
            // typed query and the visible list matches what the user clicked. The
            // selected index desyncs if we re-filter after the field commits the
            // (decorated) label, so capturing here is what makes picking a
            // non-first suggestion work.
            let index = combo.indexOfSelectedItem
            let visible = visibleLabels(for: combo.stringValue)
            guard visible.indices.contains(index) else { return }
            let label = visible[index]
            // Map the (possibly decorated) dropdown label back to the plain
            // display name, matching what the naming sheet stores.
            let selectedOption = SpeakerNameSelectionPolicy.option(
                matching: label,
                optionsByLabel: optionsByLabel,
                displayName: { $0.displayName }
            )
            let resolved = selectedOption?.displayName ?? label
            // Assign on the next tick so this lands *after* the combo commits its
            // own selected value, overriding the decorated label with the plain
            // name instead of being clobbered by it.
            DispatchQueue.main.async { [weak self] in
                combo.stringValue = resolved
                self?.parent.text = resolved
                self?.parent.selectedOptionID?.wrappedValue = selectedOption?.id
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
            if commandSelector == #selector(NSResponder.cancelOperation(_:)),
               let onCancel = parent.onCancel {
                onCancel()
                return true
            }
            return false
        }
    }
}

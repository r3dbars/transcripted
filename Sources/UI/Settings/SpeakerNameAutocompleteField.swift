import SwiftUI
import AppKit
import Combine

/// Name field with a SwiftUI suggestion list under it. Typing stays free-form
/// (no inline completion); the list reuses `SpeakerNameTypingSuggestionPolicy`
/// so Home and Speakers rank names the same way the island popup does.
struct SpeakerNameAutocompleteField: View {
    @Binding var text: String
    var placeholder: String
    var options: [SpeakerNameChoice]
    /// Carries the exact saved-person UUID selected from the list. Typing
    /// clears it, so callers can distinguish a new name from choosing one of
    /// two saved people who happen to share the same display name.
    var selectedOptionID: Binding<UUID?>? = nil
    /// When a picker opens prefilled with the current transcript label, that
    /// label is not a search query. The list stays hidden until the person types.
    var untouchedPrefill: String? = nil
    var accessibilityIdentifier: String?
    var autoFocus = false
    var onSubmit: () -> Void
    var onCancel: (() -> Void)? = nil

    @StateObject private var session = SpeakerNameAutocompleteSession()

    var body: some View {
        let suggestions = speakerNameFieldSuggestions(
            query: text,
            session: session,
            options: options,
            untouchedPrefill: untouchedPrefill
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 4) {
                SpeakerNameAutocompleteNSField(
                    text: $text,
                    placeholder: placeholder,
                    options: options,
                    selectedOptionID: selectedOptionID,
                    untouchedPrefill: untouchedPrefill,
                    accessibilityIdentifier: accessibilityIdentifier,
                    autoFocus: autoFocus,
                    session: session,
                    onSubmit: onSubmit,
                    onCancel: onCancel
                )
                .frame(height: 28)

                if !options.isEmpty {
                    browseButton
                }
            }

            if !suggestions.isEmpty {
                suggestionList(suggestions)
            }
        }
        .zIndex(1)
    }

    private var browseButton: some View {
        Button {
            session.toggleBrowseAll()
        } label: {
            Image(systemName: session.isBrowsingAll ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LibraryTokens.ink3)
                .frame(width: 22, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(session.isBrowsingAll ? "Hide saved people" : "Browse saved people")
        .accessibilityIdentifier(browseIdentifier)
    }

    @ViewBuilder
    private func suggestionList(
        _ suggestions: [SpeakerNameTypingSuggestionPolicy.Suggestion]
    ) -> some View {
        let list = SpeakerNameSuggestionList(
            suggestions: suggestions,
            visualHighlightIndex: session.visualHighlightIndex,
            selectedIndex: session.keyboardHighlightIndex,
            accessibilityIdentifier: accessibilityIdentifier,
            onPointerInside: { session.pointerInsideList = $0 },
            onHoverRow: { index, hovering in
                if hovering {
                    session.hoverEntered(index: index)
                } else {
                    session.hoverExited(index: index)
                }
            },
            onSelect: { suggestion in
                applySuggestion(suggestion)
            }
        )
        if session.isBrowsingAll {
            ScrollView {
                list
            }
            .frame(maxHeight: 220)
        } else {
            list
        }
    }

    private var browseIdentifier: String {
        if let accessibilityIdentifier, !accessibilityIdentifier.isEmpty {
            return "\(accessibilityIdentifier).browse"
        }
        return "transcripted.speaker-name.browse"
    }

    private func applySuggestion(_ suggestion: SpeakerNameTypingSuggestionPolicy.Suggestion) {
        text = suggestion.person.displayName
        selectedOptionID?.wrappedValue = suggestion.person.id
        session.commitPick()
    }
}

/// AppKit field editor for typing, marked text, and keys. The SwiftUI wrapper
/// owns the suggestion list; this box never installs combo-style completion.
struct SpeakerNameAutocompleteNSField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var options: [SpeakerNameChoice]
    var selectedOptionID: Binding<UUID?>? = nil
    var untouchedPrefill: String? = nil
    var accessibilityIdentifier: String?
    var autoFocus = false
    var session: SpeakerNameAutocompleteSession
    var onSubmit: () -> Void
    var onCancel: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = makeTextField(coordinator: context.coordinator)
        session.field = field
        return field
    }

    func makeTextField(coordinator: Coordinator) -> NSTextField {
        let field = NSTextField()
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.delegate = coordinator
        field.font = NSFont.systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.stringValue = text
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        if let accessibilityIdentifier {
            field.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
            field.setAccessibilityIdentifier(accessibilityIdentifier)
        }
        if autoFocus {
            DispatchQueue.main.async {
                guard field.window != nil else { return }
                field.window?.makeFirstResponder(field)
            }
        }
        session.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        session.field = field
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.isDismantled = true
        coordinator.session.field = nil
        field.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SpeakerNameAutocompleteNSField
        /// Set once SwiftUI tears the view down. Work already queued must
        /// check it before touching bindings.
        var isDismantled = false
        let session: SpeakerNameAutocompleteSession

        init(_ parent: SpeakerNameAutocompleteNSField) {
            self.parent = parent
            self.session = parent.session
            super.init()
        }

        func currentSuggestions(for query: String? = nil) -> [SpeakerNameTypingSuggestionPolicy.Suggestion] {
            speakerNameFieldSuggestions(
                query: query ?? parent.text,
                session: session,
                options: parent.options,
                untouchedPrefill: parent.untouchedPrefill
            )
        }

        func applySuggestion(
            _ suggestion: SpeakerNameTypingSuggestionPolicy.Suggestion,
            field: NSTextField? = nil
        ) {
            let resolved = suggestion.person.displayName
            field?.stringValue = resolved
            parent.text = resolved
            parent.selectedOptionID?.wrappedValue = suggestion.person.id
            session.commitPick()
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            session.isFocused = true
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.selectedOptionID?.wrappedValue = nil
            session.queryChanged()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Always drop keyboard focus. `pointerInsideList` keeps the rows
            // mounted for this turn so a mouse-down can land; the next turn
            // clears it so Tab / click-away cannot leave the list stuck.
            session.isFocused = false
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDismantled else { return }
                self.session.pointerInsideList = false
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard let field = control as? NSTextField else { return false }
            let suggestions = currentSuggestions(for: field.stringValue)

            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                session.keyboardHighlightIndex = SpeakerNameTypingSuggestionPolicy.movedHighlight(
                    from: session.keyboardHighlightIndex,
                    by: 1,
                    count: suggestions.count
                )
                return !suggestions.isEmpty
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                session.keyboardHighlightIndex = SpeakerNameTypingSuggestionPolicy.movedHighlight(
                    from: session.keyboardHighlightIndex,
                    by: -1,
                    count: suggestions.count
                )
                return !suggestions.isEmpty
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                switch SpeakerNameTypingSuggestionPolicy.returnDecision(
                    highlighted: session.keyboardHighlightIndex,
                    suggestionCount: suggestions.count,
                    hoverHighlight: session.hoverHighlightIndex
                ) {
                case .selectIndex(let index):
                    applySuggestion(suggestions[index], field: field)
                    parent.onSubmit()
                    return true
                case .submitTyped:
                    parent.text = field.stringValue
                    parent.onSubmit()
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                switch SpeakerNameTypingSuggestionPolicy.escapeDecision(
                    suggestionsVisible: !suggestions.isEmpty,
                    hasCancelHandler: parent.onCancel != nil
                ) {
                case .hideSuggestions:
                    session.dismissList()
                    return true
                case .cancel:
                    parent.onCancel?()
                    return true
                case .ignore:
                    return false
                }
            }
            return false
        }
    }
}

@MainActor
final class SpeakerNameAutocompleteSession: ObservableObject {
    @Published var isFocused = false
    @Published var keyboardHighlightIndex: Int? = nil
    @Published var hoverHighlightIndex: Int? = nil
    @Published var listDismissed = false
    @Published var pointerInsideList = false
    @Published var isBrowsingAll = false
    weak var field: NSTextField?

    var visualHighlightIndex: Int? { hoverHighlightIndex ?? keyboardHighlightIndex }

    func queryChanged() {
        keyboardHighlightIndex = nil
        hoverHighlightIndex = nil
        listDismissed = false
        isBrowsingAll = false
    }

    func hoverEntered(index: Int) {
        hoverHighlightIndex = index
    }

    func hoverExited(index: Int) {
        if hoverHighlightIndex == index {
            hoverHighlightIndex = nil
        }
    }

    func toggleBrowseAll() {
        isBrowsingAll.toggle()
        keyboardHighlightIndex = nil
        hoverHighlightIndex = nil
        if isBrowsingAll {
            listDismissed = false
            isFocused = true
        }
        restoreFieldFocus()
    }

    func dismissList() {
        listDismissed = true
        isBrowsingAll = false
        keyboardHighlightIndex = nil
        hoverHighlightIndex = nil
    }

    func commitPick() {
        keyboardHighlightIndex = nil
        hoverHighlightIndex = nil
        listDismissed = true
        isBrowsingAll = false
        pointerInsideList = false
        isFocused = true
        DispatchQueue.main.async { [weak self] in
            self?.isFocused = true
            self?.restoreFieldFocus()
        }
    }

    func restoreFieldFocus() {
        guard let field else { return }
        field.window?.makeFirstResponder(field)
    }
}

/// Rows under the name field. Selection happens on mouse-down so a click
/// still lands after the text field resigns first responder.
struct SpeakerNameSuggestionList: View {
    let suggestions: [SpeakerNameTypingSuggestionPolicy.Suggestion]
    var visualHighlightIndex: Int?
    var selectedIndex: Int?
    var accessibilityIdentifier: String?
    var onPointerInside: (Bool) -> Void
    var onHoverRow: (Int, Bool) -> Void
    var onSelect: (SpeakerNameTypingSuggestionPolicy.Suggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                SpeakerNameSuggestionRow(
                    label: suggestion.label,
                    isHighlighted: visualHighlightIndex == index,
                    isSelected: selectedIndex == index,
                    accessibilityIdentifier: rowIdentifier(index: index)
                ) {
                    onSelect(suggestion)
                }
                .onHover { hovering in
                    onHoverRow(index, hovering)
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 1)
        )
        .onHover(perform: onPointerInside)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(listIdentifier)
    }

    private var listIdentifier: String {
        if let accessibilityIdentifier, !accessibilityIdentifier.isEmpty {
            return "\(accessibilityIdentifier).suggestions"
        }
        return "transcripted.speaker-name.suggestions"
    }

    private func rowIdentifier(index: Int) -> String {
        "\(listIdentifier).\(index)"
    }
}

private struct SpeakerNameSuggestionRow: View {
    let label: String
    let isHighlighted: Bool
    let isSelected: Bool
    var accessibilityIdentifier: String
    let onSelect: () -> Void
    @State private var didAct = false

    var body: some View {
        Text(label)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHighlighted ? LibraryTokens.rowHover : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !didAct else { return }
                        didAct = true
                        onSelect()
                    }
                    .onEnded { _ in
                        didAct = false
                    }
            )
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onSelect() }
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityLabel(label)
    }
}

private func speakerNameFieldSuggestions(
    query: String,
    session: SpeakerNameAutocompleteSession,
    options: [SpeakerNameChoice],
    untouchedPrefill: String?
) -> [SpeakerNameTypingSuggestionPolicy.Suggestion] {
    SpeakerNameTypingSuggestionPolicy.suggestions(
        query: query,
        isFocused: session.isFocused || session.pointerInsideList,
        people: options,
        listDismissed: session.listDismissed,
        untouchedPrefill: untouchedPrefill,
        isBrowsingAll: session.isBrowsingAll
    )
}

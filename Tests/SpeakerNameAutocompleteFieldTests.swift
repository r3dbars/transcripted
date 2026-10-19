import AppKit
import SwiftUI

@MainActor
private final class SpeakerNameFieldFixture {
    var text = ""
    var selectedID: UUID?
    var submissions = 0
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let session = SpeakerNameAutocompleteSession()
    var field: SpeakerNameAutocompleteNSField!
    var coordinator: SpeakerNameAutocompleteNSField.Coordinator!
    var fieldView: NSTextField!
    var editor: NSTextView { fieldView.currentEditor() as! NSTextView }

    init(options: [SpeakerNameChoice]) {
        _ = NSApplication.shared
        field = SpeakerNameAutocompleteNSField(
            text: Binding(get: { self.text }, set: { self.text = $0 }),
            placeholder: "Name", options: options,
            selectedOptionID: Binding(get: { self.selectedID }, set: { self.selectedID = $0 }),
            session: session,
            onSubmit: { self.submissions += 1 })
        coordinator = field.makeCoordinator()
        fieldView = field.makeTextField(coordinator: coordinator)
        fieldView.frame = NSRect(x: 10, y: 20, width: 280, height: 24)
        window.contentView!.addSubview(fieldView)
        window.makeFirstResponder(fieldView)
        session.isFocused = true
    }

    func type(_ value: String) {
        for character in value {
            let string = String(character)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                        timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: string,
                                        charactersIgnoringModifiers: string, isARepeat: false, keyCode: 0)!
            editor.keyDown(with: event)
        }
    }

    func close() {
        SpeakerNameAutocompleteNSField.dismantleNSView(fieldView, coordinator: coordinator)
        window.orderOut(nil)
        fieldView.delegate = nil
        coordinator = nil
        field = nil
    }
}

@MainActor
func testSpeakerNameAutocompleteField() async {
    let samuel = SpeakerNameChoice(id: UUID(), displayName: "Samuel Example", callCount: 4)
    runSuite("Speaker name typing preserves a shorter first name and spaces") {
        let fixture = SpeakerNameFieldFixture(options: [samuel])
        defer { fixture.close() }
        fixture.type("Sam ")
        assertEqual(fixture.editor.string, "Sam ", "space must never accept Samuel Example")
        assertEqual(fixture.text, "Sam ")
        assertEqual(fixture.editor.selectedRange(), NSRange(location: 4, length: 0))
        assertNil(fixture.selectedID, "typing does not select a saved identity")
        fixture.type("New")
        assertEqual(fixture.text, "Sam New")
        fixture.editor.setSelectedRange(NSRange(location: 4, length: 3))
        fixture.type("Other")
        assertEqual(fixture.text, "Sam Other", "typing replaces only the selected text")
        fixture.editor.setSelectedRange(NSRange(location: 3, length: 0))
        fixture.type(" ")
        assertEqual(fixture.text, "Sam  Other", "inserting at the caret preserves the suffix")
        fixture.editor.deleteBackward(nil)
        assertEqual(fixture.text, "Sam Other")
    }
    runSuite("Speaker name bulk insertion and marked text stay under editor control") {
        let fixture = SpeakerNameFieldFixture(options: [samuel])
        defer { fixture.close() }
        // Paste delivers one insertText call. Do not read or replace the user's clipboard.
        fixture.editor.insertText("Sam New", replacementRange: NSRange(location: NSNotFound, length: 0))
        assertEqual(fixture.text, "Sam New")
        fixture.editor.setSelectedRange(NSRange(location: 0, length: fixture.editor.string.utf16.count))
        fixture.editor.setMarkedText("Sam ", selectedRange: NSRange(location: 4, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
        assertTrue(fixture.editor.hasMarkedText(), "composition remains marked until the input method commits")
        assertEqual(fixture.editor.string, "Sam ")
        fixture.editor.insertText("Sam New", replacementRange: NSRange(location: NSNotFound, length: 0))
        assertEqual(fixture.text, "Sam New")
        assertNil(fixture.selectedID)
    }
    let duplicate = SpeakerNameChoice(id: UUID(), displayName: "Samuel Example", callCount: 2)
    let fixture = SpeakerNameFieldFixture(options: [samuel, duplicate])
    defer { fixture.close() }
    runSuite("Speaker suggestions retain distinct saved identities") {
        fixture.type("Sam")
        let suggestions = fixture.coordinator.currentSuggestions(for: fixture.fieldView.stringValue)
        assertEqual(suggestions.count, 2, "loose prefix match lists both saved people")
        assertEqual(suggestions.map(\.person.id), [samuel.id, duplicate.id])
        fixture.coordinator.applySuggestion(suggestions[1], field: fixture.fieldView)
    }
    runSuite("Explicit non-first suggestion selection commits its plain name and exact UUID") {
        assertEqual(fixture.text, "Samuel Example")
        assertEqual(fixture.selectedID, duplicate.id)
        fixture.editor.setSelectedRange(NSRange(location: 0, length: fixture.editor.string.utf16.count))
        fixture.type("Sam New")
        assertEqual(fixture.text, "Sam New")
        assertNil(fixture.selectedID, "editing a selection clears its identity")
        let handled = fixture.coordinator.control(fixture.fieldView, textView: fixture.editor,
                                                  doCommandBy: #selector(NSResponder.insertNewline(_:)))
        assertTrue(handled)
        assertEqual(fixture.submissions, 1)
        assertEqual(fixture.text, "Sam New", "Return submits typed text without accepting a prefix")
    }

    let kim = SpeakerNameChoice(id: UUID(), displayName: "Daniel Kim", callCount: 4)
    let park = SpeakerNameChoice(id: UUID(), displayName: "Daniel Park", callCount: 4)
    runSuite("Speaker name arrows highlight a suggestion and Return picks it") {
        let naming = SpeakerNameFieldFixture(options: [kim, park])
        defer { naming.close() }
        naming.type("Dan")
        let suggestions = naming.coordinator.currentSuggestions(for: naming.fieldView.stringValue)
        assertEqual(suggestions.map(\.person.displayName), ["Daniel Kim", "Daniel Park"])
        let moved = naming.coordinator.control(
            naming.fieldView, textView: naming.editor,
            doCommandBy: #selector(NSResponder.moveDown(_:))
        )
        assertTrue(moved, "down arrow stays in the suggestion list")
        assertEqual(naming.session.highlightedIndex, 0)
        let submitted = naming.coordinator.control(
            naming.fieldView, textView: naming.editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        assertTrue(submitted)
        assertEqual(naming.text, "Daniel Kim")
        assertEqual(naming.selectedID, kim.id)
        assertEqual(naming.submissions, 1, "Return on a highlighted row also submits")
    }

    runSuite("Speaker name Escape hides the suggestion list") {
        let naming = SpeakerNameFieldFixture(options: [kim, park])
        defer { naming.close() }
        naming.type("Dan")
        assertEqual(
            naming.coordinator.currentSuggestions(for: naming.fieldView.stringValue).count, 2
        )
        let handled = naming.coordinator.control(
            naming.fieldView, textView: naming.editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        assertTrue(handled, "Escape is consumed while the list is open")
        assertTrue(naming.session.listDismissed)
        assertEqual(
            naming.coordinator.currentSuggestions(for: naming.fieldView.stringValue).count, 0,
            "the list stays hidden until the next edit"
        )
    }
}

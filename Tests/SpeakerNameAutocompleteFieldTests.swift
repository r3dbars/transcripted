import AppKit
import SwiftUI

@MainActor
private final class SpeakerNameFieldFixture {
    var text = ""
    var selectedID: UUID?
    var submissions = 0
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                          styleMask: [.titled], backing: .buffered, defer: false)
    var field: SpeakerNameAutocompleteField!
    var coordinator: SpeakerNameAutocompleteField.Coordinator!
    var combo: NSComboBox!
    var editor: NSTextView { combo.currentEditor() as! NSTextView }

    init(options: [SpeakerNameChoice]) {
        _ = NSApplication.shared
        field = SpeakerNameAutocompleteField(
            text: Binding(get: { self.text }, set: { self.text = $0 }),
            placeholder: "Name", options: options,
            selectedOptionID: Binding(get: { self.selectedID }, set: { self.selectedID = $0 }),
            onSubmit: { self.submissions += 1 })
        coordinator = field.makeCoordinator()
        combo = field.makeComboBox(coordinator: coordinator)
        combo.frame = NSRect(x: 10, y: 20, width: 280, height: 24)
        window.contentView!.addSubview(combo)
        window.makeFirstResponder(combo)
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
        SpeakerNameAutocompleteField.dismantleNSView(combo, coordinator: coordinator)
        window.orderOut(nil)
        // Bindings capture the fixture; release the view/coordinator explicitly.
        combo.dataSource = nil
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
        assertEqual(fixture.coordinator.numberOfItems(in: fixture.combo), 2)
        fixture.combo.selectItem(at: 1)
        fixture.coordinator.comboBoxSelectionDidChange(
            Notification(name: NSComboBox.selectionDidChangeNotification, object: fixture.combo))
    }
    // Drain the selection callback's next-main-queue commit without a timing assertion.
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    runSuite("Explicit non-first suggestion selection commits its plain name and exact UUID") {
        assertEqual(fixture.text, "Samuel Example")
        assertEqual(fixture.selectedID, duplicate.id)
        fixture.editor.setSelectedRange(NSRange(location: 0, length: fixture.editor.string.utf16.count))
        fixture.type("Sam New")
        assertEqual(fixture.text, "Sam New")
        assertNil(fixture.selectedID, "editing a selection clears its identity")
        let handled = fixture.coordinator.control(fixture.combo, textView: fixture.editor,
                                                  doCommandBy: #selector(NSResponder.insertNewline(_:)))
        assertTrue(handled)
        assertEqual(fixture.submissions, 1)
        assertEqual(fixture.text, "Sam New", "Return submits typed text without accepting a prefix")
    }
}

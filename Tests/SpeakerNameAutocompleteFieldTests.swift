import AppKit
import SwiftUI

@MainActor
private final class SpeakerNameFieldFixture {
    var text = ""
    var selectedID: UUID?
    var submissions = 0
    var cancels = 0
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let session = SpeakerNameAutocompleteSession()
    var field: SpeakerNameAutocompleteNSField!
    var coordinator: SpeakerNameAutocompleteNSField.Coordinator!
    var fieldView: NSTextField!
    var editor: NSTextView { fieldView.currentEditor() as! NSTextView }

    init(options: [SpeakerNameChoice], onCancel: Bool = false) {
        _ = NSApplication.shared
        field = SpeakerNameAutocompleteNSField(
            text: Binding(get: { self.text }, set: { self.text = $0 }),
            placeholder: "Name", options: options,
            selectedOptionID: Binding(get: { self.selectedID }, set: { self.selectedID = $0 }),
            session: session,
            onSubmit: { self.submissions += 1 },
            onCancel: onCancel ? { self.cancels += 1 } : nil)
        coordinator = field.makeCoordinator()
        fieldView = field.makeTextField(coordinator: coordinator)
        fieldView.frame = NSRect(x: 10, y: 20, width: 280, height: 24)
        window.contentView!.addSubview(fieldView)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(fieldView)
        session.isFocused = true
    }

    func press(_ selector: Selector) -> Bool {
        coordinator.control(fieldView, textView: editor, doCommandBy: selector)
    }

    func endEditing() {
        coordinator.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: fieldView)
        )
    }

    func suggestions() -> [SpeakerNameTypingSuggestionPolicy.Suggestion] {
        coordinator.currentSuggestions(for: fieldView.stringValue)
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
        assertEqual(naming.session.keyboardHighlightIndex, 0)
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
        assertEqual(naming.suggestions().count, 2)
        let handled = naming.press(#selector(NSResponder.cancelOperation(_:)))
        assertTrue(handled, "Escape is consumed while the list is open")
        assertTrue(naming.session.listDismissed)
        assertEqual(
            naming.suggestions().count, 0,
            "the list stays hidden until the next edit"
        )
    }

    let ann = SpeakerNameChoice(id: UUID(), displayName: "Ann", callCount: 1)
    let anna = SpeakerNameChoice(id: UUID(), displayName: "Anna", callCount: 8)

    runSuite("Return with the list open and nothing highlighted saves the typed text") {
        let naming = SpeakerNameFieldFixture(options: [ann, anna])
        defer { naming.close() }
        naming.type("Ann")
        assertEqual(naming.suggestions().map(\.person.displayName), ["Ann", "Anna"])
        assertNil(naming.session.keyboardHighlightIndex)
        let submitted = naming.press(#selector(NSResponder.insertNewline(_:)))
        assertTrue(submitted)
        assertEqual(naming.text, "Ann", "Return without arrows keeps the typed name")
        assertNil(naming.selectedID, "Return without arrows does not file the voice under a hovered or prefix match")
        assertEqual(naming.submissions, 1)
    }

    runSuite("Brushing a suggestion does not make Return pick it") {
        let naming = SpeakerNameFieldFixture(options: [ann, anna])
        defer { naming.close() }
        naming.type("Ann")
        naming.session.hoverEntered(index: 1)
        assertEqual(naming.session.hoverHighlightIndex, 1, "brushing Anna paints that row")
        assertNil(naming.session.keyboardHighlightIndex, "hover is not a keyboard highlight")
        let submitted = naming.press(#selector(NSResponder.insertNewline(_:)))
        assertTrue(submitted)
        assertEqual(naming.text, "Ann", "Return ignores a hover that is still on Anna")
        assertNil(naming.selectedID, "brushing Anna must not file the voice under her")
    }

    runSuite("Hovering a row, then leaving it, does not change what Return picks") {
        let naming = SpeakerNameFieldFixture(options: [ann, anna])
        defer { naming.close() }
        naming.type("Ann")
        naming.session.hoverEntered(index: 1)
        naming.session.hoverExited(index: 1)
        assertNil(naming.session.hoverHighlightIndex, "leaving the row clears the hover paint")
        let submitted = naming.press(#selector(NSResponder.insertNewline(_:)))
        assertTrue(submitted)
        assertEqual(naming.text, "Ann")
        assertNil(naming.selectedID, "Return after a hover-exit still saves the typed text")
    }

    runSuite("Return follows the arrow highlight even if another row is hovered") {
        let naming = SpeakerNameFieldFixture(options: [ann, anna])
        defer { naming.close() }
        naming.type("Ann")
        assertTrue(naming.press(#selector(NSResponder.moveDown(_:))))
        assertEqual(naming.session.keyboardHighlightIndex, 0)
        assertEqual(
            naming.session.visualHighlightIndex,
            naming.session.keyboardHighlightIndex,
            "after an arrow the painted row is the Return target"
        )
        naming.session.hoverEntered(index: 1)
        assertEqual(
            naming.session.visualHighlightIndex,
            naming.session.keyboardHighlightIndex,
            "hovering Anna must not cover the Ann row Return will save"
        )
        let submitted = naming.press(#selector(NSResponder.insertNewline(_:)))
        assertTrue(submitted)
        assertEqual(naming.text, "Ann")
        assertEqual(naming.selectedID, ann.id, "Return files under the arrow row, not the hovered one")
    }

    runSuite("Hover then an arrow paints the keyboard row Return will save") {
        let naming = SpeakerNameFieldFixture(options: [ann, anna])
        defer { naming.close() }
        naming.type("Ann")
        naming.session.hoverEntered(index: 1)
        assertEqual(naming.session.visualHighlightIndex, 1, "resting on Anna paints Anna")
        assertTrue(naming.press(#selector(NSResponder.moveDown(_:))))
        assertNil(naming.session.hoverHighlightIndex, "Down clears the hover so the keyboard row can paint")
        assertEqual(naming.session.keyboardHighlightIndex, 0)
        assertEqual(
            naming.session.visualHighlightIndex,
            naming.session.keyboardHighlightIndex,
            "pointer on Anna then Down paints Ann, which Return saves"
        )
        let submitted = naming.press(#selector(NSResponder.insertNewline(_:)))
        assertTrue(submitted)
        assertEqual(naming.text, "Ann")
        assertEqual(naming.selectedID, ann.id)
    }

    await runSuite("Tab and click-away always drop focus so the list cannot stick") {
        let naming = SpeakerNameFieldFixture(options: [ann, anna])
        defer { naming.close() }
        naming.type("Ann")
        naming.session.pointerInsideList = true
        naming.endEditing()
        assertFalse(naming.session.isFocused, "end editing always clears focus")
        assertEqual(
            naming.suggestions().count, 2,
            "the pointer flag only keeps the list mounted long enough for a click"
        )
        await drainMainQueue()
        assertFalse(naming.session.pointerInsideList, "the pointer flag clears on the next turn")
        assertEqual(naming.suggestions().count, 0, "click-away does not leave the list over the next row")
    }

    await runSuite("A click pick keeps the name field focused") {
        let naming = SpeakerNameFieldFixture(options: [ann, anna])
        defer { naming.close() }
        naming.type("Ann")
        let suggestions = naming.suggestions()
        naming.window.makeFirstResponder(nil)
        assertNil(naming.fieldView.currentEditor(), "the click first resigns the field")
        naming.coordinator.applySuggestion(suggestions[1], field: naming.fieldView)
        await drainMainQueue()
        assertNotNil(naming.fieldView.currentEditor(), "picking a row puts the caret back in the field")
        assertEqual(naming.selectedID, anna.id)
        assertTrue(naming.session.isFocused)
    }

    runSuite("The first Escape hides the list; the second cancels") {
        let naming = SpeakerNameFieldFixture(options: [ann, anna], onCancel: true)
        defer { naming.close() }
        naming.type("Ann")
        assertTrue(naming.press(#selector(NSResponder.cancelOperation(_:))))
        assertEqual(naming.cancels, 0, "the first Escape only puts the list away")
        assertEqual(naming.suggestions().count, 0)
        assertTrue(naming.press(#selector(NSResponder.cancelOperation(_:))))
        assertEqual(naming.cancels, 1, "Escape with no list dismisses the Home picker")
    }

    runSuite("The chevron lists every saved person until it is toggled off") {
        let crowd = (1...6).map { index in
            SpeakerNameChoice(id: UUID(), displayName: "Alex \(index)", callCount: 7 - index)
        }
        let naming = SpeakerNameFieldFixture(options: crowd)
        defer { naming.close() }
        assertEqual(naming.suggestions().count, 0, "an empty field has no typing list")
        naming.session.toggleBrowseAll()
        assertTrue(naming.session.isBrowsingAll)
        assertTrue(naming.session.isFocused, "the chevron keeps the field focused so the directory stays open")
        assertEqual(
            naming.suggestions().map(\.person.displayName),
            ["Alex 1", "Alex 2", "Alex 3", "Alex 4", "Alex 5", "Alex 6"],
            "browse-all is the full sorted directory"
        )
        naming.session.toggleBrowseAll()
        assertFalse(naming.session.isBrowsingAll)
        assertEqual(naming.suggestions().count, 0)
    }
}

@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

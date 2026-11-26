import AppKit
import Testing
@testable import TranscriptedKeyboard
@testable import TranscriptedWritingCore

@Suite("Ghost input controller (capture-only)")
struct GhostInputControllerTests {
    private static func keyDown(
        characters: String,
        keyCode: UInt16 = 0,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    @Test("Printable graphemes are accepted while control characters and empty strings are ignored")
    func printableGraphemeFiltering() throws {
        #expect(GhostInputController.printableGrapheme(from: try Self.keyDown(characters: "a")) == "a")
        #expect(GhostInputController.printableGrapheme(from: try Self.keyDown(characters: " ")) == " ")
        #expect(GhostInputController.printableGrapheme(from: try Self.keyDown(characters: "é")) == "é")
        #expect(GhostInputController.printableGrapheme(from: try Self.keyDown(characters: "\t", keyCode: 48)) == nil)
        #expect(GhostInputController.printableGrapheme(from: try Self.keyDown(characters: "\r", keyCode: 36)) == nil)
        #expect(GhostInputController.printableGrapheme(from: try Self.keyDown(characters: "\u{7F}", keyCode: 51)) == nil)
        #expect(GhostInputController.printableGrapheme(from: try Self.keyDown(characters: "")) == nil)
    }

    @Test("Capture-only controller never swallows events even when given a key event")
    @MainActor
    func neverConsumesKeystrokes() throws {
        let controller = GhostInputController()
        let plainKey = try Self.keyDown(characters: "x")
        let tabKey = try Self.keyDown(characters: "\t", keyCode: 48)
        let cmdKey = try Self.keyDown(characters: "c", modifiers: [.command])

        #expect(controller.handle(plainKey, client: nil) == false)
        #expect(controller.handle(tabKey, client: nil) == false)
        #expect(controller.handle(cmdKey, client: nil) == false)
    }
}

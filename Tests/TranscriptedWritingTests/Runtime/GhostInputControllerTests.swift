import AppKit
import InputMethodKit
import Testing
@testable import TranscriptedKeyboard
@testable import TranscriptedWritingCore

@Suite("Ghost input controller (capture-only)")
struct GhostInputControllerTests {
    /// Minimal `IMKTextInput` double that records cross-process IPC calls
    /// (`bundleIdentifier()` and `selectedRange()`) without touching any real
    /// host application.
    private final class FakeIMKTextInput: NSObject, IMKTextInput {
        var bundleID: String?
        var selection: NSRange
        private(set) var bundleIdentifierCallCount = 0
        private(set) var selectedRangeCallCount = 0

        init(bundleID: String? = "com.apple.TextEdit", selection: NSRange = NSRange(location: 0, length: 0)) {
            self.bundleID = bundleID
            self.selection = selection
        }

        func insertText(_ string: Any!, replacementRange: NSRange) {}
        func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {}
        func selectedRange() -> NSRange {
            selectedRangeCallCount += 1
            return selection
        }
        func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
        func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
        func length() -> Int { selection.location + selection.length }
        func characterIndex(
            for point: NSPoint,
            tracking mappingMode: IMKLocationToOffsetMappingMode,
            inMarkedRange: UnsafeMutablePointer<ObjCBool>!
        ) -> Int { NSNotFound }
        func attributes(
            forCharacterIndex index: Int,
            lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!
        ) -> [AnyHashable: Any]! { [:] }
        func validAttributesForMarkedText() -> [Any]! { [] }
        func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
        func selectMode(_ modeIdentifier: String!) {}
        func supportsUnicode() -> Bool { true }
        func bundleIdentifier() -> String! {
            bundleIdentifierCallCount += 1
            return bundleID
        }
        func windowLevel() -> CGWindowLevel { 0 }
        func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
        func uniqueClientIdentifierString() -> String! { "fake-client" }
        func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { nil }
        func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
    }

    private final class RecordedBatches: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[PersonalHistoryEvent]] = []

        func append(_ batch: [PersonalHistoryEvent]) {
            lock.withLock { batches.append(batch) }
        }

        var allEvents: [PersonalHistoryEvent] {
            lock.withLock { batches.flatMap { $0 } }
        }
    }

    private static func keyDown(
        characters: String,
        keyCode: UInt16 = 0,
        modifiers: NSEvent.ModifierFlags = [],
        type: NSEvent.EventType = .keyDown
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type,
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

    @MainActor
    private static func makeHarness(
        enabled: Bool = true,
        pausedUntil: Double = 0,
        secureInput: @escaping () -> Bool = { false },
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
    ) -> (GhostInputController, WritingTestDefaults, PersonalHistoryCapture, RecordedBatches) {
        let defaults = WritingTestDefaults()
        defaults.set(enabled, forKey: PersonalHistorySettingsContract.enabledKey)
        defaults.set("hist-1", forKey: PersonalHistorySettingsContract.historyIdentifierKey)
        defaults.set("consent-1", forKey: PersonalHistorySettingsContract.consentIdentifierKey)
        if pausedUntil > 0 {
            defaults.set(pausedUntil, forKey: PersonalHistorySettingsContract.pausedUntilKey)
        }
        let recorded = RecordedBatches()
        let capture = PersonalHistoryCapture(
            defaults: defaults,
            now: now,
            flushScheduler: .init { _, _, _ in },
            sender: { batch in
                recorded.append(batch)
                return .recorded
            }
        )
        let controller = GhostInputController()
        controller.defaults = defaults
        controller.capture = capture
        controller.isSecureEventInputEnabled = secureInput
        controller.now = now
        return (controller, defaults, capture, recorded)
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

    @Test("Capture-disabled fast-path returns false without calling client.bundleIdentifier()")
    @MainActor
    func captureDisabledFastPathSkipsClientIPC() async throws {
        let (controller, _, capture, recorded) = Self.makeHarness(enabled: false)
        let client = FakeIMKTextInput()

        #expect(controller.handle(try Self.keyDown(characters: "a"), client: client) == false)
        #expect(controller.handle(try Self.keyDown(characters: "\u{7F}", keyCode: 51), client: client) == false)
        #expect(client.bundleIdentifierCallCount == 0, "disabled keyboard must never hit client IPC")
        #expect(client.selectedRangeCallCount == 0, "disabled keyboard must never query selection IPC")

        await capture.flushAndWait()
        #expect(recorded.allEvents.isEmpty)
    }

    @Test("Plain printable keys always pass through and forward typed events")
    @MainActor
    func plainKeysPassThroughAndRecord() async throws {
        let (controller, _, capture, recorded) = Self.makeHarness(enabled: true)
        let client = FakeIMKTextInput(bundleID: "com.apple.TextEdit", selection: NSRange(location: 0, length: 0))

        #expect(controller.handle(try Self.keyDown(characters: "h"), client: client) == false)
        client.selection = NSRange(location: 1, length: 0)
        #expect(controller.handle(try Self.keyDown(characters: "i"), client: client) == false)

        #expect(client.bundleIdentifierCallCount == 2)
        #expect(client.selectedRangeCallCount == 2)
        #expect(controller.historyDeletions.hasTrackedText)

        await capture.flushAndWait()
        #expect(recorded.allEvents.count == 1)
        #expect(recorded.allEvents.first?.source == .typed)
        #expect(recorded.allEvents.first?.text == "hi")
        #expect(recorded.allEvents.first?.appBundleIdentifier == "com.apple.TextEdit")
    }

    @Test("Backspace passes through and records a deletion for tracked text, and skips IPC when nothing is tracked")
    @MainActor
    func backspacePassThroughAndDeletionTracking() async throws {
        let (controller, _, capture, recorded) = Self.makeHarness(enabled: true)
        let client = FakeIMKTextInput(bundleID: "com.apple.TextEdit", selection: NSRange(location: 0, length: 0))

        // Backspace before any tracked typing: no client IPC.
        #expect(controller.handle(try Self.keyDown(characters: "\u{7F}", keyCode: 51), client: client) == false)
        #expect(client.bundleIdentifierCallCount == 0)

        // Type "ab" then Backspace at caret 2.
        #expect(controller.handle(try Self.keyDown(characters: "a"), client: client) == false)
        client.selection = NSRange(location: 1, length: 0)
        #expect(controller.handle(try Self.keyDown(characters: "b"), client: client) == false)
        client.selection = NSRange(location: 2, length: 0)
        #expect(controller.handle(try Self.keyDown(characters: "\u{7F}", keyCode: 51), client: client) == false)

        await capture.flushAndWait()
        #expect(recorded.allEvents.count == 2)
        #expect(recorded.allEvents[0].source == .typed)
        #expect(recorded.allEvents[0].text == "ab")
        #expect(recorded.allEvents[1].source == .deletion)
        #expect(recorded.allEvents[1].deletedCharacters == 1)
    }

    @Test("Modifier chords (Command, Control, Option, Function) pass through, break segment, and skip client IPC")
    @MainActor
    func modifierChordsPassThroughAndBreakSegment() async throws {
        let (controller, _, capture, recorded) = Self.makeHarness(enabled: true)
        let client = FakeIMKTextInput(bundleID: "com.apple.TextEdit", selection: NSRange(location: 0, length: 0))

        let chords: [NSEvent.ModifierFlags] = [[.command], [.control], [.option], [.function]]
        for (offset, modifier) in chords.enumerated() {
            client.selection = NSRange(location: offset, length: 0)
            #expect(controller.handle(try Self.keyDown(characters: "a"), client: client) == false)
            let callsBeforeChord = client.bundleIdentifierCallCount
            let segmentBeforeChord = controller.historySegmentIdentifier

            #expect(controller.handle(try Self.keyDown(characters: "c", modifiers: modifier), client: client) == false)
            #expect(client.bundleIdentifierCallCount == callsBeforeChord, "modifier chord must not call bundleIdentifier()")
            #expect(controller.historySegmentIdentifier != segmentBeforeChord, "modifier chord must rotate segment")
            #expect(!controller.historyDeletions.hasTrackedText, "modifier chord must clear tracked deletions")
        }

        await capture.flushAndWait()
        #expect(recorded.allEvents.count == chords.count)
    }

    @Test("Secure Event Input passes through, wipes buffered events, and skips client IPC")
    @MainActor
    func secureEventInputWipesBufferAndSkipsIPC() async throws {
        var secure = false
        let (controller, _, capture, recorded) = Self.makeHarness(
            enabled: true,
            secureInput: { secure }
        )
        let client = FakeIMKTextInput(bundleID: "com.apple.TextEdit", selection: NSRange(location: 0, length: 0))

        #expect(controller.handle(try Self.keyDown(characters: "a"), client: client) == false)
        #expect(client.bundleIdentifierCallCount == 1)
        let segmentBeforeSecure = controller.historySegmentIdentifier

        secure = true
        #expect(controller.handle(try Self.keyDown(characters: "p"), client: client) == false)
        #expect(client.bundleIdentifierCallCount == 1, "Secure Event Input must not touch client IPC")
        #expect(controller.historySegmentIdentifier != segmentBeforeSecure)
        #expect(!controller.historyDeletions.hasTrackedText)

        await capture.flushAndWait()
        #expect(recorded.allEvents.isEmpty, "sensitiveInputBegan must wipe pending buffered events")
    }

    @Test("Paused state passes through without IPC and resumes cleanly after pause expiry")
    @MainActor
    func pausedStateSkipsIPCAndResumesAfterExpiry() async throws {
        let baseTimestamp: TimeInterval = 1_800_000_000
        let clockBox = OSAllocatedClock(now: Date(timeIntervalSince1970: baseTimestamp))
        let (controller, _, capture, recorded) = Self.makeHarness(
            enabled: true,
            pausedUntil: baseTimestamp + 3_600,
            now: { clockBox.current() }
        )
        let client = FakeIMKTextInput(bundleID: "com.apple.TextEdit", selection: NSRange(location: 0, length: 0))

        #expect(controller.handle(try Self.keyDown(characters: "x"), client: client) == false)
        #expect(client.bundleIdentifierCallCount == 0, "paused state must not call bundleIdentifier()")

        // Advance past pause expiry: capture resumes.
        clockBox.set(Date(timeIntervalSince1970: baseTimestamp + 3_601))
        #expect(controller.handle(try Self.keyDown(characters: "y"), client: client) == false)
        #expect(client.bundleIdentifierCallCount == 1)

        await capture.flushAndWait()
        #expect(recorded.allEvents.count == 1)
        #expect(recorded.allEvents.first?.text == "y")
    }

    @Test("Non-printable keys, non-keyDown events, and nil client always pass through")
    @MainActor
    func nonPrintableNonKeyDownAndNilClientPassThrough() throws {
        let (controller, _, _, _) = Self.makeHarness(enabled: true)
        let client = FakeIMKTextInput(bundleID: "com.apple.TextEdit", selection: NSRange(location: 0, length: 0))

        let tabKey = try Self.keyDown(characters: "\t", keyCode: 48)
        let returnKey = try Self.keyDown(characters: "\r", keyCode: 36)
        let keyUp = try Self.keyDown(characters: "x", type: .keyUp)
        let plainKey = try Self.keyDown(characters: "x")

        #expect(controller.handle(tabKey, client: client) == false)
        #expect(controller.handle(returnKey, client: client) == false)
        #expect(controller.handle(keyUp, client: client) == false)
        #expect(controller.handle(plainKey, client: nil) == false)
        #expect(client.bundleIdentifierCallCount == 0)
    }
}

private final class OSAllocatedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(now: Date) {
        self.date = now
    }

    func current() -> Date {
        lock.withLock { date }
    }

    func set(_ newDate: Date) {
        lock.withLock { date = newDate }
    }
}

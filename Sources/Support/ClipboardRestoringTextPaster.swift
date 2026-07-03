// ClipboardRestoringTextPaster.swift
// Pastes text into the current target app by borrowing the clipboard briefly
// and restoring the prior clipboard contents after the target reads the text.

import AppKit
import ApplicationServices
import Carbon
import Foundation

enum TextPasteCopyReason: Equatable {
    case accessibilityMissing
    case pasteEventCreationFailed
    case focusChanged
    case pasteNotConfirmed
}

enum TextPasteOutcome: Equatable {
    case pasted
    case copied(String, reason: TextPasteCopyReason)
    case failed(String)

    var diagnosticName: String {
        switch self {
        case .pasted:
            return "pasted"
        case .copied:
            return "copied"
        case .failed:
            return "failed"
        }
    }

    var diagnosticMessage: String {
        switch self {
        case .pasted:
            return "Dictation pasted successfully"
        case .copied(let message, reason: _), .failed(let message):
            return message
        }
    }

    var copyReason: TextPasteCopyReason? {
        switch self {
        case .copied(_, reason: let reason):
            return reason
        case .pasted, .failed:
            return nil
        }
    }
}

@MainActor
protocol ClipboardPasteboard: AnyObject {
    var changeCount: Int { get }
    var pasteboardItems: [NSPasteboardItem]? { get }

    @discardableResult
    func clearContents() -> Int

    @discardableResult
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool

    func string(forType dataType: NSPasteboard.PasteboardType) -> String?

    @discardableResult
    func writePasteboardItems(_ items: [NSPasteboardItem]) -> Bool
}

extension NSPasteboard: ClipboardPasteboard {
    @discardableResult
    func writePasteboardItems(_ items: [NSPasteboardItem]) -> Bool {
        writeObjects(items)
    }
}

private func postClipboardPasteShortcut() -> Bool {
    let pasteKeyCode = currentPasteShortcutKeyCode()
    guard let vDown = CGEvent(keyboardEventSource: nil, virtualKey: pasteKeyCode, keyDown: true),
          let vUp = CGEvent(keyboardEventSource: nil, virtualKey: pasteKeyCode, keyDown: false) else {
        return false
    }

    vDown.flags = .maskCommand
    vDown.post(tap: .cghidEventTap)

    vUp.flags = .maskCommand
    vUp.post(tap: .cghidEventTap)

    return true
}

private func currentPasteShortcutKeyCode() -> CGKeyCode {
    resolveCurrentKeyboardLayoutKeyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
}

private func resolveCurrentKeyboardLayoutKeyCode(for targetCharacter: Character) -> CGKeyCode? {
    guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let layoutProperty = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
        return nil
    }

    let layoutData = unsafeBitCast(layoutProperty, to: CFData.self)
    guard let layoutBytes = CFDataGetBytePtr(layoutData) else { return nil }
    let keyboardLayout = UnsafeRawPointer(layoutBytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    let target = String(targetCharacter).lowercased()

    for keyCode in UInt16(0)..<UInt16(128) {
        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDown),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &actualLength,
            &characters
        )
        guard status == noErr, actualLength > 0 else { continue }
        let produced = String(utf16CodeUnits: characters, count: actualLength).lowercased()
        if produced == target {
            return CGKeyCode(keyCode)
        }
    }

    return nil
}

enum ClipboardTargetActivationPolicy {
    /// Pure wait decision used by `waitForTargetActivation`: keep waiting only while the
    /// target is not yet frontmost AND the elapsed time has not reached the timeout.
    static func shouldWait(targetIsFrontmost: Bool, elapsed: TimeInterval, timeout: TimeInterval) -> Bool {
        guard !targetIsFrontmost else { return false }
        return elapsed < timeout
    }
}

struct DictationPasteTarget: Equatable {
    let processIdentifier: pid_t?
    let bundleIdentifier: String?

    static func capture(sourceApp: NSRunningApplication?) -> DictationPasteTarget? {
        guard let sourceApp else { return nil }
        return DictationPasteTarget(
            processIdentifier: sourceApp.processIdentifier,
            bundleIdentifier: sourceApp.bundleIdentifier
        )
    }

    func matchesCurrentFrontmostApp() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        return matches(
            processIdentifier: frontmostApp.processIdentifier,
            bundleIdentifier: frontmostApp.bundleIdentifier
        )
    }

    func matches(processIdentifier currentProcessIdentifier: pid_t?, bundleIdentifier currentBundleIdentifier: String?) -> Bool {
        if let processIdentifier, let currentProcessIdentifier {
            return processIdentifier == currentProcessIdentifier
        }
        if let bundleIdentifier, let currentBundleIdentifier {
            return bundleIdentifier == currentBundleIdentifier
        }
        return false
    }
}

private struct FocusedTextPasteConfirmation {
    private let focusedElement: AXUIElement
    private let initialValue: String?

    static func capture() -> FocusedTextPasteConfirmation? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        ) == .success,
            let focusedElement = focusedElementValue else {
            return nil
        }

        let element = focusedElement as! AXUIElement
        return FocusedTextPasteConfirmation(
            focusedElement: element,
            initialValue: stringAttribute(kAXValueAttribute as CFString, from: element)
        )
    }

    func containsPastedText(_ text: String) -> Bool {
        guard !text.isEmpty,
              let currentValue = Self.stringAttribute(kAXValueAttribute as CFString, from: focusedElement),
              currentValue != initialValue else {
            return false
        }
        return currentValue.contains(text)
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

@MainActor
final class ClipboardRestoringTextPaster {
    struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let isComplete: Bool
    }

    private static let eagerlySnapshottedPasteboardTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .rtf,
        .html,
        .tabularText,
        .URL,
        .fileURL
    ]

    private struct PendingClipboardRestore {
        let savedItems: PasteboardSnapshot
        let temporaryString: String
        let temporaryChangeCount: Int
        let pasteboard: any ClipboardPasteboard
        let generation: Int
    }

    private var clipboardRestoreTask: Task<Void, Never>?
    private var clipboardAutoEnterReadinessTask: Task<Void, Never>?
    private var clipboardAutoEnterReadyGeneration: Int?
    private var pendingClipboardRestore: PendingClipboardRestore?
    private var temporaryPasteboardDataProvider: TemporaryPasteboardStringProvider?
    private var pasteGeneration = 0

    deinit {
        clipboardRestoreTask?.cancel()
        clipboardAutoEnterReadinessTask?.cancel()
    }

    func cancelPendingClipboardRestore() {
        restorePendingClipboardNow()
    }

    func restorePendingClipboardNow() {
        guard let pendingClipboardRestore else {
            clearPendingClipboardRestore(restore: false)
            return
        }

        clearPendingClipboardRestore(restore: false)
        restorePasteboardItems(
            pendingClipboardRestore.savedItems,
            temporaryString: pendingClipboardRestore.temporaryString,
            temporaryChangeCount: pendingClipboardRestore.temporaryChangeCount,
            to: pendingClipboardRestore.pasteboard
        )
    }

    func waitForPendingClipboardRestore() async {
        while let clipboardRestoreTask {
            await clipboardRestoreTask.value
        }
    }

    func waitForClipboardReadyForAutoEnter() async {
        while let readinessTask = clipboardAutoEnterReadinessTask {
            await readinessTask.value
        }
        if clipboardAutoEnterReadyGeneration == pasteGeneration {
            return
        }
        await waitForPendingClipboardRestore()
    }

    func paste(
        _ text: String,
        target: DictationPasteTarget? = nil,
        activationWait: TimeInterval = TranscriptedConstants.clipboardTargetActivationWait,
        pasteboard: any ClipboardPasteboard = NSPasteboard.general,
        accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() },
        requestAccessibilityTrust: () -> Void = {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        },
        pasteDispatcher: @MainActor () -> Bool = postClipboardPasteShortcut,
        pasteConfirmed: (@MainActor () -> Bool)? = nil,
        restoreDelay: UInt64 = TranscriptedConstants.clipboardRestoreDelay,
        fallbackRestoreDelay: UInt64 = TranscriptedConstants.clipboardRestoreFallbackDelay,
        pasteConfirmationWait: TimeInterval = TranscriptedConstants.clipboardPasteConfirmationWait
    ) -> TextPasteOutcome {
        restorePendingClipboardBeforeNewPaste()

        if let target,
           !target.matchesCurrentFrontmostApp(),
           !waitForTargetActivation(target, timeout: activationWait) {
            copyTextToClipboard(text, to: pasteboard)
            return .copied(
                "Focus changed before Transcripted could paste, so the text was copied.",
                reason: .focusChanged
            )
        }

        guard accessibilityTrusted() else {
            requestAccessibilityTrust()
            copyTextToClipboard(text, to: pasteboard)
            return .copied(
                "Couldn't paste automatically. Accessibility is off, so the text was copied.",
                reason: .accessibilityMissing
            )
        }

        let accessibilityConfirmation = FocusedTextPasteConfirmation.capture()
        let confirmPasteReceived = pasteConfirmed ?? {
            accessibilityConfirmation?.containsPastedText(text) == true
        }

        let savedItems = snapshotPasteboardItems(from: pasteboard)
        guard savedItems.isComplete else {
            return .failed("Couldn't paste automatically without risking your current clipboard. The dictation was saved, but paste-back did not run.")
        }
        pasteGeneration += 1
        let generation = pasteGeneration
        var temporaryChangeCount = 0

        pasteboard.clearContents()
        let wroteTemporaryString = writeTemporaryString(text, to: pasteboard)

        if !wroteTemporaryString {
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string),
                  pasteboard.string(forType: .string) == text else {
                return .failed("Couldn't prepare the clipboard for automatic paste. The dictation was saved, but paste-back did not run.")
            }
        }
        temporaryChangeCount = pasteboard.changeCount

        scheduleClipboardRestore(
            savedItems,
            temporaryString: text,
            temporaryChangeCount: temporaryChangeCount,
            to: pasteboard,
            generation: generation,
            delay: fallbackRestoreDelay
        )

        guard pasteDispatcher() else {
            restorePendingClipboardNow()
            guard copyTextToClipboard(text, to: pasteboard) else {
                return .failed("Couldn't prepare the clipboard for automatic paste. The dictation was saved, but paste-back did not run.")
            }
            return .copied(
                "Couldn't paste automatically. The text was copied instead.",
                reason: .pasteEventCreationFailed
            )
        }

        guard waitForPasteConfirmation(
            target: target,
            pasteConfirmed: confirmPasteReceived,
            timeout: pasteConfirmationWait
        ) else {
            leaveTemporaryClipboardAvailable()
            return .copied(
                "Transcripted tried to paste, but could not confirm the target received it. The text stays copied.",
                reason: .pasteNotConfirmed
            )
        }

        scheduleClipboardRestore(
            savedItems,
            temporaryString: text,
            temporaryChangeCount: temporaryChangeCount,
            to: pasteboard,
            generation: generation,
            delay: restoreDelay
        )
        return .pasted
    }

    private func restorePendingClipboardBeforeNewPaste() {
        guard let pendingClipboardRestore else {
            clearPendingClipboardRestore(restore: false)
            return
        }

        clearPendingClipboardRestore(restore: false)
        restorePasteboardItems(
            pendingClipboardRestore.savedItems,
            temporaryString: pendingClipboardRestore.temporaryString,
            temporaryChangeCount: pendingClipboardRestore.temporaryChangeCount,
            to: pendingClipboardRestore.pasteboard
        )
    }

    private func clearPendingClipboardRestore(restore: Bool, keepTemporaryProvider: Bool = false) {
        pasteGeneration += 1
        clipboardRestoreTask?.cancel()
        clipboardRestoreTask = nil
        clipboardAutoEnterReadinessTask?.cancel()
        clipboardAutoEnterReadinessTask = nil
        clipboardAutoEnterReadyGeneration = nil
        let pending = pendingClipboardRestore
        pendingClipboardRestore = nil
        if !keepTemporaryProvider {
            temporaryPasteboardDataProvider = nil
        }
        guard restore, let pending else { return }
        restorePasteboardItems(
            pending.savedItems,
            temporaryString: pending.temporaryString,
            temporaryChangeCount: pending.temporaryChangeCount,
            to: pending.pasteboard
        )
    }

    private func leaveTemporaryClipboardAvailable() {
        clearPendingClipboardRestore(restore: false, keepTemporaryProvider: true)
    }

    private func scheduleClipboardAutoEnterReadiness(generation: Int, delay: UInt64) {
        guard generation == pasteGeneration,
              clipboardAutoEnterReadyGeneration != generation else { return }

        clipboardAutoEnterReadinessTask?.cancel()
        clipboardAutoEnterReadinessTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self,
                  !Task.isCancelled,
                  self.pasteGeneration == generation else { return }
            self.clipboardAutoEnterReadyGeneration = generation
            self.clipboardAutoEnterReadinessTask = nil
        }
    }

    private func scheduleClipboardRestore(
        _ savedItems: PasteboardSnapshot,
        temporaryString: String,
        temporaryChangeCount: Int,
        to pasteboard: any ClipboardPasteboard,
        generation: Int,
        delay: UInt64
    ) {
        guard generation == pasteGeneration else { return }
        clipboardRestoreTask?.cancel()
        pendingClipboardRestore = PendingClipboardRestore(
            savedItems: savedItems,
            temporaryString: temporaryString,
            temporaryChangeCount: temporaryChangeCount,
            pasteboard: pasteboard,
            generation: generation
        )
        clipboardRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self,
                  !Task.isCancelled,
                  self.pasteGeneration == generation else { return }
            self.restorePasteboardItems(
                savedItems,
                temporaryString: temporaryString,
                temporaryChangeCount: temporaryChangeCount,
                to: pasteboard
            )
            self.temporaryPasteboardDataProvider = nil
            if self.pendingClipboardRestore?.generation == generation {
                self.pendingClipboardRestore = nil
            }
            self.clipboardRestoreTask = nil
            self.clipboardAutoEnterReadinessTask?.cancel()
            self.clipboardAutoEnterReadinessTask = nil
            self.clipboardAutoEnterReadyGeneration = generation
            if self.pasteGeneration == generation {
                self.pasteGeneration += 1
            }
        }
    }

    private func waitForTargetActivation(_ target: DictationPasteTarget, timeout: TimeInterval) -> Bool {
        guard timeout > 0 else { return false }

        let start = Date()
        while ClipboardTargetActivationPolicy.shouldWait(
            targetIsFrontmost: false,
            elapsed: Date().timeIntervalSince(start),
            timeout: timeout
        ) {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if target.matchesCurrentFrontmostApp() {
                return true
            }
        }
        return target.matchesCurrentFrontmostApp()
    }

    @discardableResult
    func copyTextToClipboard(_ text: String, to pasteboard: any ClipboardPasteboard = NSPasteboard.general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
            && pasteboard.string(forType: .string) == text
    }

    @discardableResult
    func writeTemporaryString(
        _ text: String,
        to pasteboard: any ClipboardPasteboard
    ) -> Bool {
        guard pasteboard is NSPasteboard else { return false }

        let provider = TemporaryPasteboardStringProvider(
            text: text,
            onTemporaryStringRead: {}
        )
        let item = NSPasteboardItem()
        guard item.setDataProvider(provider, forTypes: [.string]) else {
            return false
        }

        guard pasteboard.writePasteboardItems([item]) else {
            temporaryPasteboardDataProvider = nil
            return false
        }

        temporaryPasteboardDataProvider = provider
        return true
    }

    private func waitForPasteConfirmation(
        target: DictationPasteTarget?,
        pasteConfirmed: @MainActor () -> Bool,
        timeout: TimeInterval
    ) -> Bool {
        guard target?.matchesCurrentFrontmostApp() != false else { return false }
        if pasteConfirmed() {
            return true
        }
        guard timeout > 0 else { return false }

        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            guard target?.matchesCurrentFrontmostApp() != false else { return false }
            if pasteConfirmed() {
                return true
            }
        }
        return pasteConfirmed()
    }

    func snapshotPasteboardItems(from pasteboard: any ClipboardPasteboard) -> PasteboardSnapshot {
        var isComplete = true
        let items: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            var typeData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard Self.eagerlySnapshottedPasteboardTypes.contains(type) else {
                    isComplete = false
                    continue
                }
                guard let data = item.data(forType: type),
                      data.count <= TranscriptedConstants.clipboardSnapshotMaxTypeBytes else {
                    isComplete = false
                    continue
                }
                if !data.isEmpty {
                    typeData[type] = data
                }
            }
            return typeData
        } ?? []
        return PasteboardSnapshot(items: items, isComplete: isComplete)
    }

    func restorePasteboardItems(
        _ savedItems: PasteboardSnapshot,
        temporaryString: String,
        temporaryChangeCount: Int,
        to pasteboard: any ClipboardPasteboard
    ) {
        guard savedItems.isComplete else { return }
        guard pasteboard.changeCount == temporaryChangeCount,
              pasteboard.string(forType: .string) == temporaryString else {
            return
        }

        pasteboard.clearContents()
        let items = savedItems.items.map { typeData -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in typeData {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writePasteboardItems(items)
        }
    }
}

private final class TemporaryPasteboardStringProvider: NSObject, NSPasteboardItemDataProvider {
    private let text: String
    private let onTemporaryStringRead: () -> Void
    private let lock = NSLock()
    private var didNotifyRead = false

    var didProvideData: Bool {
        lock.lock()
        let value = didNotifyRead
        lock.unlock()
        return value
    }

    init(text: String, onTemporaryStringRead: @escaping () -> Void) {
        self.text = text
        self.onTemporaryStringRead = onTemporaryStringRead
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .string else { return }
        item.setString(text, forType: .string)
        notifyReadOnce()
    }

    private func notifyReadOnce() {
        lock.lock()
        let shouldNotify = !didNotifyRead
        didNotifyRead = true
        lock.unlock()

        if shouldNotify {
            onTemporaryStringRead()
        }
    }
}

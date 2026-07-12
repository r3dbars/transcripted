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
    case pasteConfirmationUnavailable
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

struct ClipboardPasteConfirmationDiagnostic: Equatable {
    let event: String
    let context: [String: String]
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

    static func preferredDestination(
        frontmostProcessIdentifier: pid_t?,
        frontmostBundleIdentifier: String?,
        transcriptedBundleIdentifier: String?,
        fallback: DictationPasteTarget?
    ) -> DictationPasteTarget? {
        guard let frontmostProcessIdentifier,
              let frontmostBundleIdentifier,
              frontmostBundleIdentifier != transcriptedBundleIdentifier else {
            return fallback
        }
        return DictationPasteTarget(
            processIdentifier: frontmostProcessIdentifier,
            bundleIdentifier: frontmostBundleIdentifier
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

enum FocusedTextPasteConfirmationPolicy {
    struct SelectionRange: Equatable {
        let location: Int
        let length: Int
    }

    static func observableString(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    static func didObservePaste(
        initialValue: String?,
        currentValue: String?,
        pastedText: String,
        replacedSelectionLength: Int = 0
    ) -> Bool {
        guard let initialValue,
              let currentValue,
              currentValue != initialValue,
              !pastedText.isEmpty else {
            return false
        }

        let normalizedInitial = normalizedForConfirmation(initialValue)
        let normalizedCurrent = normalizedForConfirmation(currentValue)
        let normalizedPaste = normalizedForConfirmation(pastedText)
        if !normalizedPaste.isEmpty,
           !normalizedInitial.contains(normalizedPaste),
           normalizedCurrent.contains(normalizedPaste) {
            return true
        }

        let expectedLengthChange = pastedText.utf16.count - max(0, replacedSelectionLength)
        let observedLengthChange = currentValue.utf16.count - initialValue.utf16.count
        let tolerance = max(2, pastedText.utf16.count / 20)
        return abs(observedLengthChange - expectedLengthChange) <= tolerance
    }

    static func didObserveSelectionPaste(
        initialRange: SelectionRange?,
        currentRange: SelectionRange?,
        pastedText: String,
        clipboardWasRead: Bool
    ) -> Bool {
        guard clipboardWasRead,
              let initialRange,
              let currentRange,
              !pastedText.isEmpty,
              currentRange.length == 0 else {
            return false
        }

        let expectedCursorLocation = initialRange.location + pastedText.utf16.count
        let tolerance = max(2, pastedText.utf16.count / 20)
        return abs(currentRange.location - expectedCursorLocation) <= tolerance
    }

    static func didObserveTargetChange(
        pasteDispatchedAt: CFAbsoluteTime,
        clipboardReadAt: CFAbsoluteTime?,
        targetChangedAt: CFAbsoluteTime?
    ) -> Bool {
        guard let clipboardReadAt,
              let targetChangedAt,
              clipboardReadAt >= pasteDispatchedAt,
              targetChangedAt >= clipboardReadAt else {
            return false
        }
        return targetChangedAt - clipboardReadAt <= 1.0
    }

    private static func normalizedForConfirmation(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private func focusedTextChangeObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let tracker = Unmanaged<FocusedTextChangeObserver>.fromOpaque(refcon).takeUnretainedValue()
    tracker.recordChange()
}

private final class FocusedTextChangeObserver {
    private let focusedElement: AXUIElement
    private let lock = NSLock()
    private var observer: AXObserver?
    private var monitoredNotifications: [CFString] = []
    private var latestChangeTimestamp: CFAbsoluteTime?

    var changedAt: CFAbsoluteTime? {
        lock.lock()
        let value = latestChangeTimestamp
        lock.unlock()
        return value
    }

    private init(focusedElement: AXUIElement) {
        self.focusedElement = focusedElement
    }

    static func start(for focusedElement: AXUIElement) -> FocusedTextChangeObserver? {
        let tracker = FocusedTextChangeObserver(focusedElement: focusedElement)
        return tracker.install() ? tracker : nil
    }

    fileprivate func recordChange() {
        lock.lock()
        latestChangeTimestamp = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    private func install() -> Bool {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &processIdentifier) == .success else {
            return false
        }

        var createdObserver: AXObserver?
        guard AXObserverCreate(
            processIdentifier,
            focusedTextChangeObserverCallback,
            &createdObserver
        ) == .success,
              let createdObserver else {
            return false
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            if AXObserverAddNotification(
                createdObserver,
                focusedElement,
                notification as CFString,
                refcon
            ) == .success {
                monitoredNotifications.append(notification as CFString)
            }
        }
        guard !monitoredNotifications.isEmpty else { return false }

        observer = createdObserver
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .commonModes
        )
        return true
    }

    deinit {
        guard let observer else { return }
        for notification in monitoredNotifications {
            AXObserverRemoveNotification(observer, focusedElement, notification)
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }
}

private struct FocusedTextPasteConfirmation {
    /// Accessibility clients can otherwise block for several seconds when an editor is
    /// briefly busy applying a paste (Notes is a common example). Confirmation is a
    /// best-effort signal and must never stall delivery or the target application.
    private static let messagingTimeout: Float = 0.05

    private let focusedElement: AXUIElement
    private let initialValue: String?
    private let replacedSelectionLength: Int
    private let initialSelectionRange: FocusedTextPasteConfirmationPolicy.SelectionRange?
    private let changeObserver: FocusedTextChangeObserver?

    var canObservePaste: Bool {
        initialValue != nil || initialSelectionRange != nil || changeObserver != nil
    }

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

        // AXUIElement is a toll-free-bridged CF opaque type: Swift can't runtime-check
        // `as?`/`as!` against it (the compiler treats the downcast as unconditionally
        // successful), so CFGetTypeID is the actual safety net before we hand this
        // value to AX APIs that assume it really is an AXUIElement. This file is
        // compiled directly into the fast-test binary without the TranscriptedCore
        // module's search path (see APP_SOURCES in run-tests.sh), so importing that
        // module here isn't an option — this follows the same fputs(..., stderr)
        // idiom Sources/Observability/AppLogSink.swift itself falls back to for
        // internal diagnostics.
        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            fputs("⚠️ ClipboardRestoringTextPaster | focused UI element attribute returned an unexpected CF type (expected AXUIElement)\n", stderr)
            return nil
        }
        let element = focusedElement as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return FocusedTextPasteConfirmation(
            focusedElement: element,
            initialValue: stringAttribute(kAXValueAttribute as CFString, from: element),
            replacedSelectionLength: stringAttribute(kAXSelectedTextAttribute as CFString, from: element)?.utf16.count ?? 0,
            initialSelectionRange: selectionRangeAttribute(from: element),
            changeObserver: FocusedTextChangeObserver.start(for: element)
        )
    }

    func confirmationMode(
        _ text: String,
        clipboardWasRead: Bool,
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> String? {
        if FocusedTextPasteConfirmationPolicy.didObservePaste(
            initialValue: initialValue,
            currentValue: Self.stringAttribute(kAXValueAttribute as CFString, from: focusedElement),
            pastedText: text,
            replacedSelectionLength: replacedSelectionLength
        ) {
            return "text_value"
        }
        if FocusedTextPasteConfirmationPolicy.didObserveSelectionPaste(
            initialRange: initialSelectionRange,
            currentRange: Self.selectionRangeAttribute(from: focusedElement),
            pastedText: text,
            clipboardWasRead: clipboardWasRead
        ) {
            return "selection_range"
        }
        if FocusedTextPasteConfirmationPolicy.didObserveTargetChange(
            pasteDispatchedAt: pasteDispatchedAt,
            clipboardReadAt: clipboardReadAt,
            targetChangedAt: changeObserver?.changedAt
        ) {
            return "target_change_notification"
        }
        return nil
    }

    func diagnosticsContext(
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> [String: String] {
        [
            "clipboard_read_after_dispatch": "\((clipboardReadAt ?? 0) >= pasteDispatchedAt)",
            "target_change_after_dispatch": "\((changeObserver?.changedAt ?? 0) >= pasteDispatchedAt)",
            "target_change_observer_available": "\(changeObserver != nil)",
            "target_selection_observable": "\(initialSelectionRange != nil)",
            "target_text_observable": "\(initialValue != nil)",
        ]
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return FocusedTextPasteConfirmationPolicy.observableString(from: value)
    }

    private static func selectionRangeAttribute(
        from element: AXUIElement
    ) -> FocusedTextPasteConfirmationPolicy.SelectionRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0,
              range.length >= 0 else {
            return nil
        }
        return FocusedTextPasteConfirmationPolicy.SelectionRange(
            location: range.location,
            length: range.length
        )
    }
}

@MainActor
final class ClipboardRestoringTextPaster {
    struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let isComplete: Bool
    }

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
    private(set) var lastConfirmationDiagnostic: ClipboardPasteConfirmationDiagnostic?

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
        lastConfirmationDiagnostic = nil
        restorePendingClipboardBeforeNewPaste()

        if let target,
           !target.matchesCurrentFrontmostApp(),
           !waitForTargetActivation(target, timeout: activationWait) {
            copyTextToClipboard(text, to: pasteboard)
            return .copied(
                "Focus moved before the text could paste. It's on your clipboard — press ⌘V to paste it.",
                reason: .focusChanged
            )
        }

        guard accessibilityTrusted() else {
            requestAccessibilityTrust()
            copyTextToClipboard(text, to: pasteboard)
            return .copied(
                "Accessibility is off, so Transcripted can't paste for you. Your text is on the clipboard — press ⌘V.",
                reason: .accessibilityMissing
            )
        }

        let accessibilityConfirmation = FocusedTextPasteConfirmation.capture()
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
                return .failed("Couldn't paste or copy the text automatically. It's still saved in your dictation history.")
            }
        }
        temporaryChangeCount = pasteboard.changeCount
        let temporaryProvider = temporaryPasteboardDataProvider

        scheduleClipboardRestore(
            savedItems,
            temporaryString: text,
            temporaryChangeCount: temporaryChangeCount,
            to: pasteboard,
            generation: generation,
            delay: fallbackRestoreDelay
        )

        let pasteDispatchedAt = CFAbsoluteTimeGetCurrent()
        guard pasteDispatcher() else {
            restorePendingClipboardNow()
            guard copyTextToClipboard(text, to: pasteboard) else {
                return .failed("Couldn't paste or copy the text automatically. It's still saved in your dictation history.")
            }
            return .copied(
                "Couldn't paste automatically. Your text is on the clipboard — press ⌘V.",
                reason: .pasteEventCreationFailed
            )
        }

        let confirmationUnavailable = pasteConfirmed == nil && accessibilityConfirmation?.canObservePaste != true
        let confirmPasteReceived = pasteConfirmed ?? {
            if accessibilityConfirmation?.confirmationMode(
                text,
                clipboardWasRead: temporaryProvider?.didProvideData == true,
                clipboardReadAt: temporaryProvider?.firstReadAt,
                pasteDispatchedAt: pasteDispatchedAt
            ) != nil {
                return true
            }
            return false
        }

        let pasteWasConfirmed = waitForPasteConfirmation(
            target: target,
            pasteConfirmed: confirmPasteReceived,
            timeout: pasteConfirmationWait
        )
        guard pasteWasConfirmed else {
            var diagnostics = accessibilityConfirmation?.diagnosticsContext(
                clipboardReadAt: temporaryProvider?.firstReadAt,
                pasteDispatchedAt: pasteDispatchedAt
            ) ?? [
                "clipboard_read_after_dispatch": "\((temporaryProvider?.firstReadAt ?? 0) >= pasteDispatchedAt)",
                "target_change_after_dispatch": "false",
                "target_change_observer_available": "false",
                "target_selection_observable": "false",
                "target_text_observable": "false",
            ]
            diagnostics["target_still_frontmost"] = "\(target?.matchesCurrentFrontmostApp() != false)"
            lastConfirmationDiagnostic = ClipboardPasteConfirmationDiagnostic(
                event: "dictation_paste_confirmation_diagnostics",
                context: diagnostics
            )
            guard leaveTemporaryClipboardAvailable() else {
                return .failed("Couldn't keep the dictation copied after paste-back was unconfirmed. The dictation was saved, but paste-back did not run.")
            }
            if confirmationUnavailable {
                return .copied(
                    "Transcripted sent paste, but this target did not expose paste confirmation. The text stays copied.",
                    reason: .pasteConfirmationUnavailable
                )
            }
            return .copied(
                "Transcripted tried to paste, but could not confirm the target received it. The text stays copied.",
                reason: .pasteNotConfirmed
            )
        }

        let confirmationMode: String
        if pasteConfirmed != nil {
            confirmationMode = "injected_confirmation"
        } else {
            confirmationMode = accessibilityConfirmation?.confirmationMode(
                text,
                clipboardWasRead: temporaryProvider?.didProvideData == true,
                clipboardReadAt: temporaryProvider?.firstReadAt,
                pasteDispatchedAt: pasteDispatchedAt
            ) ?? "unknown"
        }
        lastConfirmationDiagnostic = ClipboardPasteConfirmationDiagnostic(
            event: "dictation_paste_confirmed",
            context: ["confirmation_mode": confirmationMode]
        )

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

    private func leaveTemporaryClipboardAvailable() -> Bool {
        guard let pendingClipboardRestore else {
            clearPendingClipboardRestore(restore: false)
            return true
        }

        let pasteboard = pendingClipboardRestore.pasteboard
        let temporaryString = pendingClipboardRestore.temporaryString
        let temporaryChangeCount = pendingClipboardRestore.temporaryChangeCount
        clearPendingClipboardRestore(restore: false)
        // A user copy with the same plain text can still carry rich data. Keep it
        // intact when the pasteboard changed after paste started. An unchanged
        // pasteboard may still hold our lazy provider, so materialize it before
        // returning the text for manual recovery.
        if pasteboard.changeCount != temporaryChangeCount {
            return true
        }
        return copyTextToClipboard(temporaryString, to: pasteboard)
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
    private var firstReadTimestamp: CFAbsoluteTime?

    var didProvideData: Bool {
        lock.lock()
        let value = didNotifyRead
        lock.unlock()
        return value
    }

    var firstReadAt: CFAbsoluteTime? {
        lock.lock()
        let value = firstReadTimestamp
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
        if firstReadTimestamp == nil {
            firstReadTimestamp = CFAbsoluteTimeGetCurrent()
        }
        lock.unlock()

        if shouldNotify {
            onTemporaryStringRead()
        }
    }
}

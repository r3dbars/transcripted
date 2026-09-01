// ClipboardRestoringTextPaster.swift
// Pastes text into the current target app by borrowing the clipboard briefly
// and restoring the prior clipboard contents after the target reads the text.

import AppKit
import ApplicationServices
import Carbon
import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

private enum ClipboardPasteConfirmationWaitResult: Equatable {
    case confirmed
    case unconfirmed
    case focusChanged
}

enum TextPasteCopyReason: Equatable {
    case accessibilityMissing
    case pasteEventCreationFailed
    case focusChanged
    case pasteNotConfirmed
    case pasteConfirmationUnavailable
    case pasteConfirmationUnavailableAutoSendEligible
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

struct ClipboardPasteTiming: Equatable {
    let startedAt: CFAbsoluteTime
    let dispatchStartedAt: CFAbsoluteTime?
    let dispatchFinishedAt: CFAbsoluteTime?
    let clipboardReadAt: CFAbsoluteTime?
    let confirmationStartedAt: CFAbsoluteTime?
    let confirmationFinishedAt: CFAbsoluteTime?

    func measurements() -> [String: Int] {
        var values: [String: Int] = [:]
        values["paste_prepare_ms"] = milliseconds(from: startedAt, to: dispatchStartedAt)
        values["paste_dispatch_ms"] = milliseconds(from: dispatchStartedAt, to: dispatchFinishedAt)
        if let dispatchStartedAt,
           let clipboardReadAt,
           clipboardReadAt >= dispatchStartedAt {
            values["paste_clipboard_read_ms"] = milliseconds(
                from: dispatchStartedAt,
                to: clipboardReadAt
            )
        }
        values["paste_confirmation_wait_ms"] = milliseconds(
            from: confirmationStartedAt,
            to: confirmationFinishedAt
        )
        return values
    }

    private func milliseconds(from start: CFAbsoluteTime?, to end: CFAbsoluteTime?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int(((end - start) * 1_000).rounded()))
    }
}

enum DictationTargetConfirmationMode: String, Equatable {
    case textValue = "text_value"
    case selectionRange = "selection_range"
    case changeNotification = "change_notification"
    case clipboardReadOnly = "clipboard_read_only"
    case none

    static func resolve(
        outcome: TextPasteOutcome,
        diagnostic: ClipboardPasteConfirmationDiagnostic?
    ) -> DictationTargetConfirmationMode {
        if outcome.copyReason == .pasteConfirmationUnavailableAutoSendEligible {
            return .clipboardReadOnly
        }

        guard diagnostic?.event == "dictation_paste_confirmed" else {
            return .none
        }
        switch diagnostic?.context["confirmation_mode"] {
        case "text_value":
            return .textValue
        case "selection_range":
            return .selectionRange
        case "target_change_notification":
            return .changeNotification
        default:
            return .none
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

    // Key names here must not contain any sensitive-key fragment from
    // PayloadSanitizationCore (e.g. "text", "name") or the local sanitizer
    // blanks the boolean to "[redacted-sensitive-value]" in events.jsonl.
    // "target_value_observable" reports whether kAXValueAttribute was readable.
    func diagnosticsContext(
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> [String: String] {
        [
            "clipboard_read_after_dispatch": "\((clipboardReadAt ?? 0) >= pasteDispatchedAt)",
            "target_change_after_dispatch": "\((changeObserver?.changedAt ?? 0) >= pasteDispatchedAt)",
            "target_change_observer_available": "\(changeObserver != nil)",
            "target_selection_observable": "\(initialSelectionRange != nil)",
            "target_value_observable": "\(initialValue != nil)",
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
protocol ClipboardPasteConfirmationSource {
    var canObservePaste: Bool { get }

    func confirmationMode(
        _ text: String,
        clipboardWasRead: Bool,
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> String?

    func diagnosticsContext(
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> [String: String]
}

extension FocusedTextPasteConfirmation: ClipboardPasteConfirmationSource {}

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
    }

    private enum ClipboardFallbackState: String {
        case dictationPresent = "dictation_present"
        case clipboardChanged = "clipboard_changed"
        case clipboardEmpty = "clipboard_empty"
        case unavailable

        var hasVerifiedDictation: Bool {
            self == .dictationPresent
        }
    }

    private static let unverifiedClipboardRecoveryFailure =
        "Transcripted sent paste, but could not confirm it, and could not verify a recovery copy on the clipboard. The dictation is saved in your history."

    private var clipboardRestoreTask: Task<Void, Never>?
    private var clipboardAutoEnterReadinessTask: Task<Void, Never>?
    private var clipboardAutoEnterReadyToken: SupersessionEpoch.Token?
    private var pendingClipboardRestore = ClaimSlot<PendingClipboardRestore>()
    private var retainedClipboardRestoreForPasteRetry: PendingClipboardRestore?
    private var temporaryPasteboardDataProvider: TemporaryPasteboardStringProvider?
    /// Epoch — begun per paste attempt, invalidated whenever the pending restore
    /// is cleared, superseded when a scheduled restore completes
    private var pasteEpoch = SupersessionEpoch()
    private(set) var lastConfirmationDiagnostic: ClipboardPasteConfirmationDiagnostic?
    private(set) var lastPasteTiming: ClipboardPasteTiming?

    deinit {
        clipboardRestoreTask?.cancel()
        clipboardAutoEnterReadinessTask?.cancel()
    }

    func cancelPendingClipboardRestore() {
        restorePendingClipboardNow()
        restoreRetainedClipboardNow()
    }

    func discardPasteRetry() {
        restoreRetainedClipboardNow()
    }

    func restorePendingClipboardNow() {
        guard let pending = clearPendingClipboardRestore() else { return }
        restorePasteboardItems(
            pending.savedItems,
            temporaryString: pending.temporaryString,
            temporaryChangeCount: pending.temporaryChangeCount,
            to: pending.pasteboard
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
        if let readyToken = clipboardAutoEnterReadyToken, pasteEpoch.isCurrent(readyToken) {
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
        confirmationSource: (@MainActor () -> (any ClipboardPasteConfirmationSource)?)? = nil,
        pasteConfirmed: (@MainActor () -> Bool)? = nil,
        targetIsFrontmost: (@MainActor () -> Bool)? = nil,
        prepareForAutoSend: Bool = false,
        retainClipboardForPasteRetry: Bool = true,
        restoreDelay: UInt64 = TranscriptedConstants.clipboardRestoreDelay,
        fallbackRestoreDelay: UInt64 = TranscriptedConstants.clipboardRestoreFallbackDelay,
        pasteConfirmationWait: TimeInterval = TranscriptedConstants.clipboardPasteConfirmationWait
    ) -> TextPasteOutcome {
        lastConfirmationDiagnostic = nil
        lastPasteTiming = nil
        let timingStartedAt = CFAbsoluteTimeGetCurrent()
        var timingDispatchStartedAt: CFAbsoluteTime?
        var timingDispatchFinishedAt: CFAbsoluteTime?
        var timingConfirmationStartedAt: CFAbsoluteTime?
        var timingConfirmationFinishedAt: CFAbsoluteTime?
        var timingProvider: TemporaryPasteboardStringProvider?
        defer {
            lastPasteTiming = ClipboardPasteTiming(
                startedAt: timingStartedAt,
                dispatchStartedAt: timingDispatchStartedAt,
                dispatchFinishedAt: timingDispatchFinishedAt,
                clipboardReadAt: timingProvider?.firstReadAt,
                confirmationStartedAt: timingConfirmationStartedAt,
                confirmationFinishedAt: timingConfirmationFinishedAt
            )
        }
        discardPasteRetry()
        restorePendingClipboardNow()

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

        let accessibilityConfirmation = confirmationSource?() ?? FocusedTextPasteConfirmation.capture()
        let savedItems = snapshotPasteboardItems(from: pasteboard)
        guard savedItems.isComplete else {
            return .failed("Couldn't paste automatically without risking your current clipboard. The dictation was saved, but paste-back did not run.")
        }
        let pasteToken = pasteEpoch.begin()
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
        timingProvider = temporaryProvider

        scheduleClipboardRestore(
            savedItems,
            temporaryString: text,
            temporaryChangeCount: temporaryChangeCount,
            to: pasteboard,
            token: pasteToken,
            delay: fallbackRestoreDelay
        )

        let pasteDispatchedAt = CFAbsoluteTimeGetCurrent()
        timingDispatchStartedAt = pasteDispatchedAt
        guard pasteDispatcher() else {
            timingDispatchFinishedAt = CFAbsoluteTimeGetCurrent()
            restorePendingClipboardNow()
            guard copyTextToClipboard(text, to: pasteboard) else {
                return .failed("Couldn't paste or copy the text automatically. It's still saved in your dictation history.")
            }
            return .copied(
                "Couldn't paste automatically. Your text is on the clipboard — press ⌘V.",
                reason: .pasteEventCreationFailed
            )
        }
        timingDispatchFinishedAt = CFAbsoluteTimeGetCurrent()

        let confirmationUnavailable = pasteConfirmed == nil && accessibilityConfirmation?.canObservePaste != true
        let targetRemainsFrontmost = targetIsFrontmost ?? {
            target?.matchesCurrentFrontmostApp() != false
        }
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
        // A target with no observable confirmation surface can never upgrade to a
        // confirmed paste inside this wait (no AX value, selection, or change
        // observer exists to fire), so once the target reads the borrowed
        // clipboard after Cmd+V the rest of the window is dead time. That holds
        // for Auto Enter targets too: the auto-send-eligible branch below acts on
        // the same read signal either way, and the follow-up keypress stays gated
        // behind the clipboard restore plus its own frontmost re-check.
        let stopWaitingAfterClipboardRead = {
            guard confirmationUnavailable,
                  let clipboardReadAt = temporaryProvider?.firstReadAt else {
                return false
            }
            return clipboardReadAt >= pasteDispatchedAt
        }

        timingConfirmationStartedAt = CFAbsoluteTimeGetCurrent()
        let pasteConfirmationResult = waitForPasteConfirmation(
            targetIsFrontmost: targetRemainsFrontmost,
            pasteConfirmed: confirmPasteReceived,
            stopWaitingUnconfirmed: stopWaitingAfterClipboardRead,
            timeout: pasteConfirmationWait
        )
        timingConfirmationFinishedAt = CFAbsoluteTimeGetCurrent()
        guard pasteConfirmationResult == .confirmed else {
            var diagnostics = accessibilityConfirmation?.diagnosticsContext(
                clipboardReadAt: temporaryProvider?.firstReadAt,
                pasteDispatchedAt: pasteDispatchedAt
            ) ?? [
                "clipboard_read_after_dispatch": "\((temporaryProvider?.firstReadAt ?? 0) >= pasteDispatchedAt)",
                "target_change_after_dispatch": "false",
                "target_change_observer_available": "false",
                "target_selection_observable": "false",
                "target_value_observable": "false",
            ]
            let targetStillFrontmost = pasteConfirmationResult == .unconfirmed
            diagnostics["target_still_frontmost"] = "\(targetStillFrontmost)"
            lastConfirmationDiagnostic = ClipboardPasteConfirmationDiagnostic(
                event: "dictation_paste_confirmation_diagnostics",
                context: diagnostics
            )
            let clipboardReadAfterDispatch = (temporaryProvider?.firstReadAt ?? 0) >= pasteDispatchedAt
            if !targetStillFrontmost {
                let clipboardFallbackState = leaveTemporaryClipboardAvailable()
                diagnostics["clipboard_fallback_state"] = clipboardFallbackState.rawValue
                lastConfirmationDiagnostic = ClipboardPasteConfirmationDiagnostic(
                    event: "dictation_paste_confirmation_diagnostics",
                    context: diagnostics
                )
                guard clipboardFallbackState.hasVerifiedDictation else {
                    return .failed(Self.unverifiedClipboardRecoveryFailure)
                }
                return .copied(
                    "Focus moved before Transcripted could confirm paste. The text is on your clipboard — press ⌘V.",
                    reason: .focusChanged
                )
            }
            if confirmationUnavailable,
               prepareForAutoSend,
               clipboardReadAfterDispatch,
               target != nil {
                scheduleClipboardRestore(
                    savedItems,
                    temporaryString: text,
                    temporaryChangeCount: temporaryChangeCount,
                    to: pasteboard,
                    token: pasteToken,
                    delay: restoreDelay
                )
                return .copied(
                    "Transcripted sent paste and the selected target read it, but the target exposed no text confirmation.",
                    reason: .pasteConfirmationUnavailableAutoSendEligible
                )
            }
            let clipboardFallbackState = leaveTemporaryClipboardAvailable()
            diagnostics["clipboard_fallback_state"] = clipboardFallbackState.rawValue
            lastConfirmationDiagnostic = ClipboardPasteConfirmationDiagnostic(
                event: "dictation_paste_confirmation_diagnostics",
                context: diagnostics
            )
            guard clipboardFallbackState.hasVerifiedDictation else {
                return .failed(Self.unverifiedClipboardRecoveryFailure)
            }

            // AX confirmation is positive-only. Some editors apply Cmd+V but do not
            // update their AX value, selection, notification, or attributed clipboard
            // read inside this short wait. A miss therefore cannot prove paste failed.
            // Keep the text copied as recovery and report the dispatch neutrally;
            // concrete clipboard, event, and focus failures still return above.
            return .copied(
                "Transcripted sent paste, but this target did not expose paste confirmation. The text stays copied.",
                reason: .pasteConfirmationUnavailable
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
            token: pasteToken,
            delay: restoreDelay
        )
        return .pasted
    }

    /// Fences out every in-flight restore/readiness task, empties the pending
    /// slot, and returns whatever restore payload was stored so the caller can
    /// decide what to do with it.
    @discardableResult
    private func clearPendingClipboardRestore() -> PendingClipboardRestore? {
        pasteEpoch.invalidate()
        clipboardRestoreTask?.cancel()
        clipboardRestoreTask = nil
        clipboardAutoEnterReadinessTask?.cancel()
        clipboardAutoEnterReadinessTask = nil
        clipboardAutoEnterReadyToken = nil
        temporaryPasteboardDataProvider = nil
        return pendingClipboardRestore.clear()
    }

    private func leaveTemporaryClipboardAvailable(
        retainingRestoreForPasteRetry: Bool = false
    ) -> ClipboardFallbackState {
        guard let pending = clearPendingClipboardRestore() else { return .unavailable }

        // A user copy with the same plain text can still carry rich data. Keep it
        // intact when the pasteboard changed after paste started, but only count
        // that as recovery when the dictation text is actually still present.
        // An unchanged pasteboard may still hold our lazy provider, so materialize
        // it before returning the text for manual recovery.
        if pending.pasteboard.changeCount != pending.temporaryChangeCount {
            guard let currentString = pending.pasteboard.string(forType: .string) else {
                return pending.pasteboard.pasteboardItems?.isEmpty == false
                    ? .clipboardChanged
                    : .clipboardEmpty
            }
            return currentString == pending.temporaryString
                ? .dictationPresent
                : .clipboardChanged
        }
        guard copyTextToClipboard(pending.temporaryString, to: pending.pasteboard) else {
            return .unavailable
        }
        if retainingRestoreForPasteRetry {
            retainedClipboardRestoreForPasteRetry = PendingClipboardRestore(
                savedItems: pending.savedItems,
                temporaryString: pending.temporaryString,
                temporaryChangeCount: pending.pasteboard.changeCount,
                pasteboard: pending.pasteboard
            )
        }
        return .dictationPresent
    }

    private func restoreRetainedClipboardNow() {
        guard let retained = retainedClipboardRestoreForPasteRetry else { return }
        retainedClipboardRestoreForPasteRetry = nil
        let pasteboard = retained.pasteboard
        guard pasteboard.changeCount == retained.temporaryChangeCount,
              pasteboard.string(forType: .string) == retained.temporaryString else {
            return
        }
        restorePasteboardItems(
            retained.savedItems,
            temporaryString: retained.temporaryString,
            temporaryChangeCount: retained.temporaryChangeCount,
            to: pasteboard
        )
    }

    private func scheduleClipboardRestore(
        _ savedItems: PasteboardSnapshot,
        temporaryString: String,
        temporaryChangeCount: Int,
        to pasteboard: any ClipboardPasteboard,
        token: SupersessionEpoch.Token,
        delay: UInt64
    ) {
        guard pasteEpoch.isCurrent(token) else { return }
        clipboardRestoreTask?.cancel()
        pendingClipboardRestore.install(
            PendingClipboardRestore(
                savedItems: savedItems,
                temporaryString: temporaryString,
                temporaryChangeCount: temporaryChangeCount,
                pasteboard: pasteboard
            ),
            ownedBy: token
        )
        clipboardRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self,
                  !Task.isCancelled,
                  self.pasteEpoch.isCurrent(token) else { return }
            self.restorePasteboardItems(
                savedItems,
                temporaryString: temporaryString,
                temporaryChangeCount: temporaryChangeCount,
                to: pasteboard
            )
            self.temporaryPasteboardDataProvider = nil
            self.pendingClipboardRestore.clearIfOwned(by: token)
            self.clipboardRestoreTask = nil
            self.clipboardAutoEnterReadinessTask?.cancel()
            self.clipboardAutoEnterReadinessTask = nil
            // Deliberately fused: publish this attempt as the Auto Enter ready
            // marker, then close its epoch so no later restore/readiness work
            // can still act on the finished attempt.
            self.clipboardAutoEnterReadyToken = token
            self.pasteEpoch.supersedeIfCurrent(token)
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
        targetIsFrontmost: @MainActor () -> Bool,
        pasteConfirmed: @MainActor () -> Bool,
        stopWaitingUnconfirmed: @MainActor () -> Bool,
        timeout: TimeInterval
    ) -> ClipboardPasteConfirmationWaitResult {
        guard targetIsFrontmost() else { return .focusChanged }
        if pasteConfirmed() {
            return targetIsFrontmost() ? .confirmed : .focusChanged
        }
        guard targetIsFrontmost() else { return .focusChanged }
        if stopWaitingUnconfirmed() {
            return .unconfirmed
        }
        guard timeout > 0 else { return .unconfirmed }

        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            guard targetIsFrontmost() else { return .focusChanged }
            if pasteConfirmed() {
                return targetIsFrontmost() ? .confirmed : .focusChanged
            }
            if stopWaitingUnconfirmed() {
                return .unconfirmed
            }
        }
        guard targetIsFrontmost() else { return .focusChanged }
        let confirmed = pasteConfirmed()
        guard targetIsFrontmost() else { return .focusChanged }
        return confirmed ? .confirmed : .unconfirmed
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

// ClipboardRestoringTextPaster+Pasteboard.swift
// The clipboard data layer: snapshot the user's clipboard (keeping privacy
// markers), put it back only when the borrowed text is still there, and copy
// plain text. Split out of ClipboardRestoringTextPaster.swift.

import AppKit
import Foundation

/// One representation from a clipboard snapshot: the bytes, or a timeout
/// before they arrived. Tests inject a reader; production bounds the wait.
enum ClipboardSnapshotTypeRead: Equatable {
    case value(Data?)
    case timedOut
}

/// Clock and reader used while snapshotting the user's clipboard. Tests
/// inject both so a stalled promised item can be simulated without sleeping.
struct ClipboardSnapshotReadContext {
    var timeout: TimeInterval
    var now: () -> TimeInterval
    var readType: (NSPasteboardItem, NSPasteboard.PasteboardType, TimeInterval) -> ClipboardSnapshotTypeRead

    static func production() -> ClipboardSnapshotReadContext {
        ClipboardSnapshotReadContext(
            timeout: TranscriptedConstants.clipboardSnapshotReadTimeout,
            now: { ProcessInfo.processInfo.systemUptime },
            readType: ClipboardSnapshotReader.readPasteboardType
        )
    }
}

enum ClipboardSnapshotReader {
    /// Wait up to `remaining` for `fetch`. A wait that never finishes is a
    /// timeout; the fetch is not treated as a nil read. Tests inject `wait`.
    static func read(
        remaining: TimeInterval,
        wait: (TimeInterval, @escaping @Sendable () -> Void) -> Bool = waitOnSnapshotQueue,
        fetch: @escaping () -> Data?
    ) -> ClipboardSnapshotTypeRead {
        guard remaining > 0 else { return .timedOut }
        let box = ClipboardSnapshotFetchBox(fetch)
        let finished = wait(remaining) { box.run() }
        return finished ? .value(box.result) : .timedOut
    }

    static func readPasteboardType(
        _ item: NSPasteboardItem,
        type: NSPasteboard.PasteboardType,
        remaining: TimeInterval
    ) -> ClipboardSnapshotTypeRead {
        read(remaining: remaining) { item.data(forType: type) }
    }

    /// Runs the fetch off the calling thread so a stalled promised item
    /// cannot hold the main actor past the bound. When called on the main
    /// thread and the fetch does not finish immediately, pumps `.defaultMode`
    /// in short slices so an own-process lazy `NSPasteboardItemDataProvider`
    /// (such as text copied inside Transcripted itself) can deliver its data
    /// instead of self-deadlocking until `remaining` expires.
    static func waitOnSnapshotQueue(_ remaining: TimeInterval, work: @escaping @Sendable () -> Void) -> Bool {
        let group = DispatchGroup()
        group.enter()
        snapshotReadQueue.async {
            work()
            group.leave()
        }
        guard Thread.isMainThread else {
            return group.wait(timeout: .now() + remaining) == .success
        }
        let fastWait = min(remaining, 0.005)
        if group.wait(timeout: .now() + fastWait) == .success {
            return true
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, remaining - fastWait)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if group.wait(timeout: .now()) == .success {
                return true
            }
            let slice = min(0.01, max(0.001, deadline - ProcessInfo.processInfo.systemUptime))
            _ = CFRunLoopRunInMode(.defaultMode, slice, true)
        }
        return group.wait(timeout: .now()) == .success
    }
}

/// `@unchecked Sendable`: the fetch and its result stay on this box; the
/// snapshot queue only calls `run`.
private final class ClipboardSnapshotFetchBox: @unchecked Sendable {
    private let fetch: () -> Data?
    private let lock = NSLock()
    private var fetched: Data??

    var result: Data? {
        lock.lock()
        defer { lock.unlock() }
        return fetched ?? nil
    }

    init(_ fetch: @escaping () -> Data?) {
        self.fetch = fetch
    }

    func run() {
        let value = fetch()
        lock.lock()
        fetched = value
        lock.unlock()
    }
}

private let snapshotReadQueue = DispatchQueue(
    label: "com.transcripted.clipboard-snapshot-read",
    qos: .userInitiated,
    attributes: .concurrent
)

extension ClipboardRestoringTextPaster {
    struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let isComplete: Bool
        /// True when any item carried an nspasteboard.org privacy marker
        /// (a password manager's concealed copy, a transient or auto-generated
        /// item). Such a clipboard is restored right after a paste as before,
        /// but never held on to for later.
        var containsPrivacyMarker = false
        /// Why an incomplete snapshot cannot be restored. Nil when complete.
        var incompleteCause: ClipboardSnapshotCause? = nil
    }

    struct ClipboardSnapshotAttempt {
        let savedItems: PasteboardSnapshot
        let snapshotMS: Int
        let refusal: TextPasteOutcome?
    }

    /// nspasteboard.org markers that say "don't keep this". Apps usually write
    /// them with empty data, so snapshots keep them even when empty.
    nonisolated static let privacyMarkerTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    /// nspasteboard.org marker for data an app puts on the clipboard only for a
    /// moment, like a paste done through Cmd+V. Clipboard managers skip items
    /// that carry it, so they neither record the dictation nor read it while it
    /// is borrowed (a read that would look like the target pasting).
    nonisolated static let transientPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// File-promise pasteboard types that cannot be faithfully restored from
    /// raw `Data` and whose eager read can trigger slow/stalling exports in
    /// Photos, Preview, Mail, Chrome, or Figma. Skipped when an item carries
    /// other readable representations; an item with ONLY promise types still
    /// refuses paste-back so the user's clipboard is never clobbered.
    nonisolated static let nonRestorablePromiseTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-suggested-file-name"),
        NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"),
        NSPasteboard.PasteboardType("Apple files promise pasteboard type"),
    ]

    /// Stably prioritizes lightweight canonical representations (privacy
    /// markers, text, URLs, HTML/RTF, PNG/PDF) ahead of heavy uncompressed,
    /// legacy, or dynamic formats (`public.tiff`, `com.apple.webarchive`,
    /// `dyn.*`). That ensures an item's cheap representations are captured
    /// before a huge secondary format can fill the snapshot byte budget or
    /// stall a lazy provider.
    nonisolated static func prioritizedSnapshotTypes(
        _ types: [NSPasteboard.PasteboardType]
    ) -> [NSPasteboard.PasteboardType] {
        func tier(for type: NSPasteboard.PasteboardType) -> Int {
            if privacyMarkerTypes.contains(type) { return 0 }
            switch type {
            case .string, .URL, .fileURL, .html, .rtf,
                 NSPasteboard.PasteboardType("public.utf16-plain-text"),
                 NSPasteboard.PasteboardType("public.utf16-external-plain-text"):
                return 0
            case .png, .pdf, .rtfd:
                return 1
            case .tiff,
                 NSPasteboard.PasteboardType("com.apple.pict"),
                 NSPasteboard.PasteboardType("com.apple.webarchive"):
                return 3
            default:
                return type.rawValue.hasPrefix("dyn.") ? 3 : 2
            }
        }
        return types.enumerated()
            .sorted { lhs, rhs in
                let lt = tier(for: lhs.element)
                let rt = tier(for: rhs.element)
                return lt == rt ? lhs.offset < rhs.offset : lt < rt
            }
            .map(\.element)
    }

    @discardableResult
    func copyTextToClipboard(_ text: String, to pasteboard: any ClipboardPasteboard = NSPasteboard.general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
            && pasteboard.string(forType: .string) == text
    }

    func snapshotPasteboardItems(
        from pasteboard: any ClipboardPasteboard,
        timeout: TimeInterval = TranscriptedConstants.clipboardSnapshotReadTimeout,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        readType: @escaping (NSPasteboardItem, NSPasteboard.PasteboardType, TimeInterval) -> ClipboardSnapshotTypeRead
            = ClipboardSnapshotReader.readPasteboardType
    ) -> PasteboardSnapshot {
        var isComplete = true
        var incompleteCause: ClipboardSnapshotCause?
        // This runs synchronously on the stop-to-paste path, so bound the whole
        // snapshot as well as each representation: one pathological clipboard
        // must not turn the stop into a multi-hundred-megabyte copy, and a
        // stalled promised item must not hang delivery.
        var totalBytes = 0
        var containsPrivacyMarker = false
        var timedOut = false
        let started = now()
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if timedOut { break }
            var typeData: [NSPasteboard.PasteboardType: Data] = [:]
            var skippedTypes = 0
            var sawReadableEmptyValue = false
            var itemCause: ClipboardSnapshotCause?
            let orderedTypes = Self.prioritizedSnapshotTypes(item.types)
            let hasRestorableCandidateTypes = orderedTypes.contains { !Self.nonRestorablePromiseTypes.contains($0) }
            for type in orderedTypes {
                if Self.nonRestorablePromiseTypes.contains(type) {
                    if !hasRestorableCandidateTypes {
                        skippedTypes += 1
                        itemCause = ClipboardSnapshotCause.preferring(itemCause, .unreadable)
                    }
                    continue
                }
                let remaining = timeout - (now() - started)
                if remaining <= 0 {
                    timedOut = true
                    skippedTypes += 1
                    itemCause = ClipboardSnapshotCause.preferring(itemCause, .timeout)
                    break
                }
                let isPrivacyMarker = Self.privacyMarkerTypes.contains(type)
                if isPrivacyMarker {
                    // Checked from the type list, before any data read, so a
                    // marker with no readable data still counts.
                    containsPrivacyMarker = true
                }
                // Once full, avoid asking additional lazy providers to allocate
                // data that cannot be retained. Individual provider fetches can
                // still exceed the budget; NSPasteboard has no size preflight.
                if totalBytes >= TranscriptedConstants.clipboardSnapshotMaxTotalBytes {
                    skippedTypes += 1
                    itemCause = ClipboardSnapshotCause.preferring(itemCause, .tooLarge)
                    continue
                }
                switch readType(item, type, remaining) {
                case .timedOut:
                    timedOut = true
                    skippedTypes += 1
                    itemCause = ClipboardSnapshotCause.preferring(itemCause, .timeout)
                case .value(nil):
                    if isPrivacyMarker {
                        // Some password managers declare privacy markers with
                        // nil data; keep the empty marker rather than failing
                        // the snapshot as unreadable.
                        typeData[type] = Data()
                    } else {
                        skippedTypes += 1
                        itemCause = ClipboardSnapshotCause.preferring(itemCause, .unreadable)
                    }
                case .value(let data?):
                    guard data.count <= TranscriptedConstants.clipboardSnapshotMaxTypeBytes,
                          totalBytes + data.count <= TranscriptedConstants.clipboardSnapshotMaxTotalBytes else {
                        skippedTypes += 1
                        itemCause = ClipboardSnapshotCause.preferring(itemCause, .tooLarge)
                        continue
                    }
                    // Keep empty privacy markers so a restored password stays
                    // marked as concealed for clipboard managers.
                    if !data.isEmpty || isPrivacyMarker {
                        typeData[type] = data
                        totalBytes += data.count
                    } else {
                        sawReadableEmptyValue = true
                    }
                }
                if timedOut { break }
            }
            // Dropping one heavy or unreadable representation (a screenshot's
            // TIFF next to its PNG) still restores the item, so it does not
            // block paste-back. Only an item that lost every representation
            // makes the snapshot incomplete — restoring it would erase the
            // user's clipboard, and that is the case paste-back refuses.
            let onlyEmptyValueWithUnreadableSecondary = sawReadableEmptyValue && itemCause == .unreadable
            if typeData.isEmpty, skippedTypes > 0, !onlyEmptyValueWithUnreadableSecondary {
                isComplete = false
                incompleteCause = ClipboardSnapshotCause.preferring(incompleteCause, itemCause ?? .unreadable)
            }
            items.append(typeData)
            if timedOut {
                // A partial snapshot must not be restored: later items were
                // never read, and writing it back would drop them.
                isComplete = false
                incompleteCause = .timeout
                break
            }
        }
        return PasteboardSnapshot(
            items: items,
            isComplete: isComplete,
            containsPrivacyMarker: containsPrivacyMarker,
            incompleteCause: isComplete ? nil : incompleteCause
        )
    }

    /// Snapshot the pasteboard and refuse paste-back when it cannot be put
    /// back later. Never clears or writes when the snapshot is incomplete.
    func snapshotClipboardForPaste(
        from pasteboard: any ClipboardPasteboard,
        read: ClipboardSnapshotReadContext = .production()
    ) -> ClipboardSnapshotAttempt {
        let snapshotStartedAt = CFAbsoluteTimeGetCurrent()
        let snapshotChangeCount = pasteboard.changeCount
        let savedItems = snapshotPasteboardItems(
            from: pasteboard,
            timeout: read.timeout,
            now: read.now,
            readType: read.readType
        )
        let snapshotMS = max(0, Int(((CFAbsoluteTimeGetCurrent() - snapshotStartedAt) * 1_000).rounded()))
        let refusal: TextPasteOutcome?
        if !savedItems.isComplete {
            let cause = savedItems.incompleteCause ?? .unreadable
            refusal = .failed(cause.refusalMessage, reason: .clipboardSnapshotIncomplete(cause))
        } else if pasteboard.changeCount != snapshotChangeCount {
            refusal = .failed(
                ClipboardSnapshotCause.changed.refusalMessage,
                reason: .clipboardSnapshotIncomplete(.changed)
            )
        } else {
            refusal = nil
        }
        return ClipboardSnapshotAttempt(savedItems: savedItems, snapshotMS: snapshotMS, refusal: refusal)
    }

    func restorePasteboardItems(
        _ savedItems: PasteboardSnapshot,
        temporaryString: String,
        temporaryChangeCount: Int,
        to pasteboard: any ClipboardPasteboard
    ) {
        restoreClipboardSnapshot(savedItems, matching: temporaryString,
            changeCount: temporaryChangeCount, to: pasteboard)
    }

    func restoreClipboardSnapshot(
        _ savedItems: PasteboardSnapshot, matching expectedString: String?,
        changeCount: Int, to pasteboard: any ClipboardPasteboard
    ) {
        guard savedItems.isComplete,
              pasteboard.changeCount == changeCount,
              pasteboard.string(forType: .string) == expectedString,
              pasteboard.changeCount == changeCount else { return }

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

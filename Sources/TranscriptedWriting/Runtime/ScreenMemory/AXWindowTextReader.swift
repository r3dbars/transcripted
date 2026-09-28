import ApplicationServices
import AppKit
#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import ScreenCaptureKit

/// Reads the frontmost window's text through the Accessibility tree — the
/// exact strings the app itself draws, with real frames, in ~1ms — instead
/// of screenshotting and OCRing pixels. Reading only: the covenant's ban on
/// an Accessibility *insertion* path stands. Used only when the user has
/// granted Tilde the Accessibility permission; apps whose trees carry no
/// text (many Chromium/Electron apps) simply return too little and the OCR
/// path runs as before. The same gates apply upstream (Screen Memory
/// toggle, Secure Input, exclusion list) because this runs inside the same
/// capture attempt that OCR would.
enum AXWindowTextReader {
    struct Result: Sendable {
        let blocks: [ScreenSnapshot.TextBlock]
        let completed: Bool
        let confidence: Double
    }

    static let nodeBudget = 3_000
    static let timeoutSeconds = 0.15
    /// Below this much text the tree is considered unreadable and the
    /// caller falls back to OCR. Set high deliberately: a thin AX read is
    /// worse than OCR, not better — live 2026-08-24 a degraded Messages
    /// tree yielded 2 blocks where OCR saw 19, and the old 2-block floor
    /// accepted it, collapsing an 8-turn conversation to 1. Windows with
    /// genuinely little text lose nothing by falling back: OCR reads them
    /// equally well.
    static let minimumBlocks = 6
    static let minimumCharacters = 150

    static func isAvailable() -> Bool { AXIsProcessTrusted() }

    private static let textRoles: Set<String> = [
        kAXStaticTextRole as String, kAXTextAreaRole as String, kAXTextFieldRole as String,
        kAXCellRole as String,
    ]

    /// Subtrees that never carry message text. Skipping them bounds huge
    /// windows and saves IPC; measured 2026-08-24 it loses zero blocks on
    /// chat windows.
    private static let prunedRoles: Set<String> = [
        kAXMenuBarRole as String, kAXMenuRole as String, kAXMenuItemRole as String,
        kAXToolbarRole as String, kAXScrollBarRole as String, kAXSplitterRole as String,
        kAXImageRole as String, kAXPopUpButtonRole as String, kAXButtonRole as String,
    ]

    /// All attributes a node might need, fetched in ONE round trip.
    /// Per-attribute AXUIElementCopyAttributeValue calls cost one IPC each;
    /// batching measured 41ms -> 27ms on a live Messages window (92 nodes).
    ///
    /// Children are deliberately NOT in this batch: asking a container for
    /// its full children array makes apps like Messages realize an
    /// accessibility object for every message in the conversation's entire
    /// history, on their main thread, every walk — a beachball in the
    /// frontmost app (live 2026-08-24). Children are fetched separately,
    /// visible-only where the app offers that, and hard-capped otherwise.
    private static let batchedAttributes = [
        kAXRoleAttribute as String,
        kAXValueAttribute as String, kAXTitleAttribute as String,
        kAXPositionAttribute as String, kAXSizeAttribute as String,
    ]

    /// Never ask any single container for more than this many children.
    static let childrenCap = 60

    /// Walks the AX window matching `window` and returns display-normalized
    /// text blocks in the exact shape the OCR path produces, or nil when
    /// the tree yields too little to trust.
    static func read(for window: SCWindow, display: SCDisplay) -> Result? {
        guard isAvailable(), let pid = window.owningApplication?.processID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // A wedged target app must cost at most one bounded call, never the
        // system default multi-second IPC timeout.
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let axWindow = matchWindow(app: app, frame: window.frame) else { return nil }
        let owner = window.owningApplication?.bundleIdentifier
        let windowFrame = ScreenCaptureService.normalize(window.frame, in: display.frame)

        var collected: [(String, CGRect)] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var queue: [AXUIElement] = [axWindow]
        var index = 0
        while index < queue.count, visited < nodeBudget, Date() < deadline {
            let element = queue[index]; index += 1; visited += 1
            let attributes = batched(element)
            let role = attributes[kAXRoleAttribute as String] as? String ?? ""
            if textRoles.contains(role) {
                let text = (attributes[kAXValueAttribute as String] as? String)
                    ?? (attributes[kAXTitleAttribute as String] as? String) ?? ""
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let frame = frame(
                       position: attributes[kAXPositionAttribute as String],
                       size: attributes[kAXSizeAttribute as String]
                   ) {
                    collected.append((text, frame))
                }
            }
            if prunedRoles.contains(role) { continue }
            queue.append(contentsOf: boundedChildren(element))
        }

        let completed = index >= queue.count
        let totalCharacters = collected.reduce(0) { $0 + $1.0.count }
        guard collected.count >= minimumBlocks, totalCharacters >= minimumCharacters else { return nil }
        let blocks = collected.map { text, frame in
            ScreenSnapshot.TextBlock(
                text: text,
                boundingBox: ScreenCaptureService.normalize(frame, in: display.frame),
                windowOwnerBundleIdentifier: owner,
                windowIdentifier: window.windowID,
                windowTitle: window.title,
                windowFrame: windowFrame,
                confidence: 1
            )
        }
        // AX strings are exact. An incomplete bounded walk is still slightly
        // less trustworthy as a *scene* than a completed one, even after it
        // clears the conservative coverage gate above.
        return Result(blocks: blocks, completed: completed, confidence: completed ? 1 : 0.9)
    }

    private static func matchWindow(app: AXUIElement, frame: CGRect) -> AXUIElement? {
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
           let list = windows as? [AXUIElement] {
            for candidate in list {
                let attrs = batched(candidate)
                if let f = self.frame(
                       position: attrs[kAXPositionAttribute as String],
                       size: attrs[kAXSizeAttribute as String]
                   ),
                   abs(f.origin.x - frame.origin.x) < 4, abs(f.origin.y - frame.origin.y) < 4,
                   abs(f.width - frame.width) < 8, abs(f.height - frame.height) < 8 {
                    return candidate
                }
            }
        }
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return (focused as! AXUIElement)
        }
        return nil
    }

    /// Visible children when the app exposes them (scroll areas, lists,
    /// tables — exactly the containers whose full arrays are huge), else a
    /// ranged fetch capped at `childrenCap`, which cannot force the target
    /// app to realize its entire backing collection.
    private static func boundedChildren(_ element: AXUIElement) -> [AXUIElement] {
        var visible: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXVisibleChildrenAttribute as CFString, &visible) == .success,
           let list = visible as? [AXUIElement], !list.isEmpty {
            return Array(list.prefix(childrenCap))
        }
        var ranged: CFArray?
        if AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, childrenCap, &ranged) == .success,
           let list = ranged as? [AXUIElement] {
            return list
        }
        return []
    }

    private static func batched(_ element: AXUIElement) -> [String: CFTypeRef] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element, batchedAttributes as CFArray, AXCopyMultipleAttributeOptions(), &values
        ) == .success, let list = values as? [CFTypeRef] else { return [:] }
        var out: [String: CFTypeRef] = [:]
        for (index, name) in batchedAttributes.enumerated() where index < list.count {
            let value = list[index]
            // Missing attributes come back as AXValue error placeholders.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
            out[name] = value
        }
        return out
    }

    private static func frame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, CFGetTypeID(position) == AXValueGetTypeID(),
              let size, CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var box = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &box) else { return nil }
        return CGRect(origin: point, size: box)
    }
}

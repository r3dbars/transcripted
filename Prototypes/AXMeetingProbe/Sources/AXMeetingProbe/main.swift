// AXMeetingProbe — dumps meeting-app AX trees and guesses the active speaker.
// Prototype only. macOS 13+. Requires Accessibility permission for the host terminal.
import AppKit
import ApplicationServices
import Foundation

// MARK: - Args

struct Options {
    var command = "watch"
    var app: String? = nil
    var depth = 25
    var hz = 2.0
    var redact = false
}

func parseArgs() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "dump", "watch": o.command = a
        case "--app": o.app = it.next()
        case "--depth": o.depth = Int(it.next() ?? "") ?? o.depth
        case "--hz": o.hz = Double(it.next() ?? "") ?? o.hz
        case "--redact": o.redact = true
        default: FileHandle.standardError.write("unknown arg \(a)\n".data(using: .utf8)!)
        }
    }
    return o
}

// MARK: - AX helpers

struct AXNode {
    let element: AXUIElement
    var role: String?, subrole: String?, title: String?, desc: String?, value: String?, identifier: String?, domClasses: [String]
}

private let attrNames: [String] = [
    kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
    kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute, "AXDOMClassList",
]

func readNode(_ el: AXUIElement) -> AXNode {
    var values: CFArray?
    _ = AXUIElementCopyMultipleAttributeValues(el, attrNames as CFArray, AXCopyMultipleAttributeOptions(), &values)
    let arr = (values as? [Any]) ?? []
    func str(_ i: Int) -> String? {
        guard i < arr.count else { return nil }
        if let s = arr[i] as? String, !s.isEmpty { return s }
        return nil
    }
    let classes = (arr.count > 6 ? arr[6] as? [String] : nil) ?? []
    return AXNode(element: el, role: str(0), subrole: str(1), title: str(2), desc: str(3), value: str(4), identifier: str(5), domClasses: classes)
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
    return (ref as? [AXUIElement]) ?? []
}

func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success else { return nil }
    return ref as? T
}

/// Depth-first walk with depth and node caps (keeps big browser DOM trees bounded).
func walk(_ root: AXUIElement, maxDepth: Int, maxNodes: Int = 4000, visit: (AXNode, Int) -> Void) {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var count = 0
    while let (el, d) = stack.popLast(), count < maxNodes {
        count += 1
        visit(readNode(el), d)
        if d < maxDepth { for c in children(el).reversed() { stack.append((c, d + 1)) } }
    }
}

// MARK: - App targeting

enum MeetingApp: String { case zoom, teams, meet }

let browserBundles = ["com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.apple.Safari", "com.brave.Browser"]

func findTargets(_ want: MeetingApp?) -> [(MeetingApp, NSRunningApplication)] {
    var out: [(MeetingApp, NSRunningApplication)] = []
    for app in NSWorkspace.shared.runningApplications {
        guard let id = app.bundleIdentifier else { continue }
        let kind: MeetingApp?
        switch id {
        case "us.zoom.xos": kind = .zoom
        case "com.microsoft.teams2", "com.microsoft.teams": kind = .teams
        case let b where browserBundles.contains(b): kind = .meet
        default: kind = nil
        }
        if let k = kind, want == nil || want == k { out.append((k, app)) }
    }
    return out
}

func meetingWindows(_ kind: MeetingApp, _ appEl: AXUIElement) -> [AXUIElement] {
    let windows: [AXUIElement] = attr(appEl, kAXWindowsAttribute) ?? []
    return windows.filter { w in
        let t = (attr(w, kAXTitleAttribute) as String?) ?? ""
        switch kind {
        case .zoom: return t.localizedCaseInsensitiveContains("Zoom Meeting") || t.localizedCaseInsensitiveContains("Zoom Webinar") || t == "Zoom"
        case .teams: return !t.isEmpty && !t.localizedCaseInsensitiveContains("Chat")
        case .meet: return t.hasPrefix("Meet") || t.localizedCaseInsensitiveContains("meet.google.com") || t.localizedCaseInsensitiveContains("Picture in picture")
        }
    }
}

/// Chromium hides web AX content unless asked. Prototype sets it; production must restore it.
func enableWebAX(_ appEl: AXUIElement) {
    AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
}

// MARK: - Name cleanup (mirrors design §3, simplified)

let suffixPatterns = [
    #"\((host|co-host|me|you|guest|external|organizer|presenter)\)"#,
    #",\s*(organizer|co-organizer|presenter|attendee|meeting guest)\b"#,
    #"\b(is speaking|is presenting|muted|unmuted|video off|pinned|raised hand)\b"#,
    #"'s (iphone|ipad|android)"#,
]
let genericNames: Set<String> = ["participant", "guest", "unknown", "phone user", "meeting room", "you", "me"]

func cleanName(_ raw: String) -> (name: String, isSelf: Bool)? {
    var s = raw.precomposedStringWithCompatibilityMapping
    let isSelf = s.range(of: #"\((me|you)\)"#, options: [.regularExpression, .caseInsensitive]) != nil
    for p in suffixPatterns { s = s.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive]) }
    s = String(String.UnicodeScalarView(s.unicodeScalars.filter { sc in
        !((sc.properties.isEmoji && sc.value > 0x238C)
          || (0xE000...0xF8FF).contains(sc.value) || sc.value == 0x200D || (0xFE00...0xFE0F).contains(sc.value))
    }))
    s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
    let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    guard letters >= 2, !genericNames.contains(s.lowercased()) else { return nil }
    return (s, isSelf)
}

func redacted(_ s: String, _ on: Bool) -> String {
    guard on else { return s }
    return "name#" + String(UInt32(truncatingIfNeeded: s.hashValue), radix: 16)
}

// MARK: - Heuristic tile + active-speaker detection

struct Snapshot { var roster: [String] = []; var selfName: String?; var active: String?; var evidence = "" }

let speakingHints = ["speaking", "active speaker", "is talking", "spricht", "parle", "hablando"]

func snapshot(_ kind: MeetingApp, window: AXUIElement, depth: Int) -> Snapshot {
    var snap = Snapshot()
    var seen = Set<String>()
    walk(window, maxDepth: depth) { n, _ in
        let label = n.desc ?? n.title ?? ""
        guard !label.isEmpty, label.count < 120 else { return }
        let lower = label.lowercased()
        let classes = n.domClasses.joined(separator: " ").lowercased()
        let tileLike = ["AXGroup", "AXButton", "AXCell", "AXRow", "AXStaticText"].contains(n.role ?? "")
        guard tileLike else { return }
        guard let c = cleanName(label) else { return }
        // Skip obvious controls ("Mute", "Share Screen", …).
        if ["mute", "unmute", "share", "leave", "end", "chat", "reactions", "record", "participants", "camera", "microphone"]
            .contains(where: { lower.hasPrefix($0) }) { return }
        if c.isSelf { snap.selfName = c.name }
        if seen.insert(c.name.lowercased()).inserted { snap.roster.append(c.name) }
        let speaking = speakingHints.contains { lower.contains($0) } || classes.contains("speaking") || classes.contains("active")
        if speaking, snap.active == nil, !c.isSelf {
            snap.active = c.name
            snap.evidence = "\(n.role ?? "?")/\(n.subrole ?? "-") label-or-class hint"
        }
    }
    return snap
}

// MARK: - Commands

func dump(_ kind: MeetingApp, _ app: NSRunningApplication, _ o: Options) {
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(appEl, 0.25)
    if kind == .meet { enableWebAX(appEl) }
    let wins = meetingWindows(kind, appEl)
    print("== \(kind.rawValue) \(app.bundleIdentifier ?? "") pid=\(app.processIdentifier) version=\(app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "?") windows=\(wins.count)")
    for w in wins {
        walk(w, maxDepth: o.depth) { n, d in
            var parts = [n.role ?? "?"]
            if let s = n.subrole { parts.append("sub=\(s)") }
            if let t = n.title { parts.append("title=\"\(redacted(t, o.redact))\"") }
            if let x = n.desc { parts.append("desc=\"\(redacted(x, o.redact))\"") }
            if let v = n.value, v.count < 80 { parts.append("value=\"\(redacted(v, o.redact))\"") }
            if let i = n.identifier { parts.append("id=\(i)") }
            if !n.domClasses.isEmpty { parts.append("class=\(n.domClasses.prefix(6).joined(separator: ","))") }
            print(String(repeating: "  ", count: d) + parts.joined(separator: " "))
        }
    }
}

func watch(_ targets: [(MeetingApp, NSRunningApplication)], _ o: Options) {
    let interval = 1.0 / max(0.2, o.hz)
    var last: String?? = .none
    let start = Date()
    while true {
        for (kind, app) in targets {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, 0.25)
            if kind == .meet { enableWebAX(appEl) }
            for w in meetingWindows(kind, appEl) {
                let t0 = Date()
                let s = snapshot(kind, window: w, depth: o.depth)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                if last == .none || last! != s.active {
                    let ts = String(format: "%7.1fs", Date().timeIntervalSince(start))
                    print("\(ts) [\(kind.rawValue)] active=\(s.active.map { redacted($0, o.redact) } ?? "-") self=\(s.selfName.map { redacted($0, o.redact) } ?? "-") roster=\(s.roster.map { redacted($0, o.redact) }) pass=\(ms)ms \(s.evidence)")
                    last = .some(s.active)
                }
            }
        }
        Thread.sleep(forTimeInterval: interval)
    }
}

let opts = parseArgs()
guard AXIsProcessTrusted() else {
    print("Accessibility permission missing for this terminal. System Settings → Privacy & Security → Accessibility.")
    exit(2)
}
let targets = findTargets(opts.app.flatMap(MeetingApp.init(rawValue:)))
guard !targets.isEmpty else { print("No Zoom/Teams/browser process found."); exit(1) }
if opts.command == "dump" { for (k, a) in targets { dump(k, a, opts) } } else { watch(targets, opts) }

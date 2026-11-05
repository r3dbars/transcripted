// CallSpeakerAXTreeReader.swift
// Reads the meeting windows of running call apps (Zoom, Teams, Slack, and
// browsers showing Meet, Teams or Zoom) over Accessibility, as plain
// `CallSpeakerAXNode` trees for `CallSpeakerTileParser`.
//
// Same rules as `BrowserWindowTitleReader`:
// - Without Accessibility (`AXIsProcessTrusted() == false`) it reads nothing.
//   It never asks for the permission.
// - Every round trip runs on one background serial queue at utility QoS.
//   Each element's messaging timeout is set before its read, capped by what
//   is left of the poll's deadline (per element, since a timeout set on an
//   app element doesn't bound calls on its children). Never system-wide.
//
// Limits and filters (unverified, not yet checked against live calls):
// - 0.25 s messaging timeout, 1.5 s deadline per poll, 4000 nodes and depth
//   60 per window. Running out marks the window truncated and withholds the
//   poll even before tiles appear: unread content may contain another call.
// - Up to 64 window titles and 8 meeting windows per app. Slack: up to 32
//   windows sharing one 4000-node budget, huddle-titled windows first (a
//   huddle can be in any), stopping at the first full read showing a huddle.
// - AX errors: a failed whole batch or malformed success cuts a window short.
//   A destroyed element (`invalidUIElement`) is skipped; unsupported custom
//   DOM attributes inside a successful full batch count as absent. A
//   windowless app (`noValue` window list) is empty, not unknown.
//   The codes are counted for the run's summary log.
// - Apps are read in `CallSpeakerReadPlan` order (native call apps, then
//   browsers, Slack last), each within a fair share of the poll's deadline.
// - Slack is walked only when a huddle is likely (a "huddle" window title, or
//   Slack holding the mic input, checked at most every
//   `slackMicrophoneRecheckInterval`); otherwise only its titles are read.
// - Not descended into: nodes with DOM class `offscreen`, Zoom's "video
//   render" tiles (read, not descended), and, in the native Zoom app only,
//   leaf roles (buttons, text, links, images...). Web and Electron trees are
//   descended fully (inferred: web hosts need a "descend everything"
//   walk; Teams' self name sits inside a button).
// - The menu bar is skipped.
//
// Chromium and Electron apps (Chrome, Edge, Brave, Arc, Teams, Slack) only
// build their web Accessibility tree when asked: once a meeting window is
// found (for Slack: once a huddle is likely), `AXManualAccessibility` is set
// on that app once per recording. It is only set while recording, and never
// reset (the app drops it on relaunch).
//
// Mic holders: the Slack check reads Core Audio process objects
// (`MicActivityMonitor.currentMicInputBundleIDs`), metadata only. It builds
// no `AVAudioEngine` and touches no `inputNode`, so a Bluetooth headset as the
// default input is never switched into call mode by it.
//
// Privacy: titles and labels hold meeting and participant names. They are
// returned to the caller in memory and never logged, stored or sent.

import AppKit
import ApplicationServices

final class CallSpeakerAXTreeReader: CallSpeakerWindowReading, @unchecked Sendable {
    static let readDeadline: TimeInterval = 1.5
    static let messagingTimeout: TimeInterval = 0.25
    static let maxWindowsPerApp = CallSpeakerReadPlan.maxWindowsPerApp
    static let maxSlackWindows = CallSpeakerReadPlan.maxSlackWindows
    static let maxNodesPerWindow = CallSpeakerReadPlan.maxNodesPerWindow
    static let maxDepth = 60
    /// How long a "does Slack hold the mic" answer is reused.
    static let slackMicrophoneRecheckInterval: TimeInterval = 3

    /// Live: Core Audio's list of processes holding the mic input. Runs on
    /// the reader's utility queue.
    static let liveSlackMicrophoneCheck: @Sendable () -> Bool = {
        CallSpeakerReadPlan.isSlackHoldingMicrophone(micInputBundleIDs: MicActivityMonitor.currentMicInputBundleIDs())
    }

    private static let manualAccessibilityAttribute = "AXManualAccessibility"
    private static let domIdentifierAttribute = "AXDOMIdentifier"
    private static let domClassListAttribute = "AXDOMClassList"

    /// One round trip per element, in this order.
    private static let attributes: [String] = [
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXRoleDescriptionAttribute,
        kAXTitleAttribute,
        kAXDescriptionAttribute,
        kAXValueAttribute,
        kAXIdentifierAttribute,
        domIdentifierAttribute,
        domClassListAttribute,
        kAXChildrenAttribute,
    ]
    private static let prunedRoles: Set<String> = [kAXMenuBarRole]
    /// Unverified: read, never descended (native Zoom only, see header).
    private static let leafRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTextField",
        "AXTextArea", "AXStaticText", "AXLink", "AXImage", "AXSlider", "AXHelpTag",
    ]
    private static let offscreenClass = "offscreen"
    private static let videoRenderRoleDescription = "video render"

    private let queue = DispatchQueue(label: "com.transcripted.call-speaker-ax", qos: .utility)
    // Confined to `queue`.
    private var manualAccessibilitySession: UUID?
    private var manualAccessibilityPIDs = Set<pid_t>()
    private var slackMicrophoneAnswer: (holds: Bool, at: Date)?
    private let slackHoldsMicrophone: @Sendable () -> Bool

    init(slackHoldsMicrophone: @escaping @Sendable () -> Bool = CallSpeakerAXTreeReader.liveSlackMicrophoneCheck) {
        self.slackHoldsMicrophone = slackHoldsMicrophone
    }

    private struct HostApp: Sendable {
        let pid: pid_t
        let bundleID: String
        let host: CallSpeakerApp.Host
    }

    private struct WalkBudget {
        var nodes = 0
        var truncated = false
        let deadline: Date
        let descendLeaves: Bool
        var diagnostics = CallSpeakerScanDiagnostics()

        mutating func truncate(_ issue: CallSpeakerScanIssue) {
            if !truncated { diagnostics.truncations[issue, default: 0] += 1 }
            truncated = true
        }

        mutating func skip(_ issue: CallSpeakerScanIssue) {
            diagnostics.skippedElements[issue, default: 0] += 1
        }
    }

    /// What one element's batch read allows.
    enum ElementReadOutcome: Equatable {
        case usable
        /// The element is gone or unreadable; leave it out, the walk goes on.
        case skip(CallSpeakerScanIssue)
        /// Part of the window couldn't be read; the window is cut short.
        case truncate(CallSpeakerScanIssue)
    }

    /// One window-list read: the windows (none for a windowless app), or why
    /// the list couldn't be read.
    enum WindowListRead {
        case windows([AXUIElement])
        case failed(CallSpeakerScanIssue)
    }

    func read(session: UUID) async -> CallSpeakerReadResult {
        guard AXIsProcessTrusted() else { return .nothingRunning }
        // Bundle IDs are read off the main thread: that read can block on
        // LaunchServices.
        let apps: [HostApp] = await RunningApplicationsReader.applications().compactMap { app in
            guard app.isRegularApp,
                  let bundleID = app.bundleIdentifier,
                  let host = CallSpeakerApp.host(forBundleID: bundleID) else { return nil }
            return HostApp(pid: app.processIdentifier, bundleID: bundleID, host: host)
        }
        guard !apps.isEmpty else { return .nothingRunning }

        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.readOnQueue(apps, session: session))
            }
        }
    }

    private func readOnQueue(_ apps: [HostApp], session: UUID) -> CallSpeakerReadResult {
        if manualAccessibilitySession != session {
            manualAccessibilitySession = session
            manualAccessibilityPIDs = []
        }
        return CallSpeakerReadPlan.scanApps(
            apps,
            host: { $0.host },
            deadline: Date().addingTimeInterval(Self.readDeadline),
            now: { Date() },
            read: { self.meetingWindows(of: $0, deadline: $1) }
        )
    }

    private func meetingWindows(of app: HostApp, deadline: Date) -> CallSpeakerReadPlan.WindowScan {
        let appElement = AXUIElementCreateApplication(app.pid)
        if let issue = boundNextRead(on: appElement, deadline: deadline) { return .incomplete(issue) }
        var windowsRef: AnyObject?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        let windows: [AXUIElement]
        switch Self.windowListValue(status: status, value: windowsRef) {
        case .windows(let list): windows = list
        case .failed(let issue): return .incomplete(issue)
        }

        return CallSpeakerReadPlan.scanWindows(
            windows,
            host: app.host,
            deadline: deadline,
            now: { Date() },
            title: { self.title(of: $0, deadline: $1) },
            slackHoldsMicrophone: { self.isSlackHoldingMicrophone() },
            prepareForWalk: { deadline in
                if CallSpeakerApp.needsManualAccessibility(bundleID: app.bundleID),
                   !self.manualAccessibilityPIDs.contains(app.pid),
                   self.boundNextRead(on: appElement, deadline: deadline) == nil {
                    AXUIElementSetAttributeValue(appElement, Self.manualAccessibilityAttribute as CFString, kCFBooleanTrue)
                    self.manualAccessibilityPIDs.insert(app.pid)
                }
            },
            readTree: { window, deadline, initialNodes in
                var budget = WalkBudget(nodes: initialNodes, deadline: deadline, descendLeaves: app.host != .zoom)
                let tree = self.walk(window, depth: 0, budget: &budget)
                // A root that was skipped (window closed mid-walk) is an
                // empty, complete read; a root cut short is truncated.
                return CallSpeakerReadPlan.TreeRead(
                    tree: tree ?? CallSpeakerAXNode(),
                    truncated: budget.truncated,
                    visitedNodes: budget.nodes,
                    diagnostics: budget.diagnostics
                )
            }
        )
    }

    /// Confined to `queue`; the answer is reused for a few seconds.
    private func isSlackHoldingMicrophone() -> Bool {
        if let answer = slackMicrophoneAnswer,
           Date().timeIntervalSince(answer.at) < Self.slackMicrophoneRecheckInterval {
            return answer.holds
        }
        let holds = slackHoldsMicrophone()
        slackMicrophoneAnswer = (holds, Date())
        return holds
    }

    private func walk(_ element: AXUIElement, depth: Int, budget: inout WalkBudget) -> CallSpeakerAXNode? {
        guard budget.nodes < Self.maxNodesPerWindow else {
            budget.truncate(.nodeCap)
            return nil
        }
        if let issue = boundNextRead(on: element, deadline: budget.deadline) {
            if issue == .ax(.invalidUIElement) { budget.skip(issue) } else { budget.truncate(issue) }
            return nil
        }
        budget.nodes += 1

        var valuesRef: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element,
            Self.attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &valuesRef
        )
        let values = valuesRef as? [AnyObject]
        switch Self.batchReadOutcome(status: status, values: values) {
        case .usable: break
        case .skip(let issue):
            budget.skip(issue)
            return nil
        case .truncate(let issue):
            budget.truncate(issue)
            return nil
        }
        guard let values else {
            budget.truncate(.unexpectedValue)
            return nil
        }

        let role = values[0] as? String
        if let role, Self.prunedRoles.contains(role) { return nil }

        var node = CallSpeakerAXNode(
            role: role,
            subrole: values[1] as? String,
            roleDescription: values[2] as? String,
            title: values[3] as? String,
            description: values[4] as? String,
            value: values[5] as? String,
            identifier: values[6] as? String,
            domIdentifier: values[7] as? String,
            domClassList: values[8] as? [String] ?? []
        )

        guard shouldDescend(node, budget: budget),
              let children = values[9] as? [AXUIElement], !children.isEmpty else { return node }
        guard depth + 1 < Self.maxDepth else {
            budget.truncate(.depthCap)
            return node
        }
        for child in children {
            guard !budget.truncated else { break }
            if let childNode = walk(child, depth: depth + 1, budget: &budget) {
                node.children.append(childNode)
            }
        }
        return node
    }

    private func shouldDescend(_ node: CallSpeakerAXNode, budget: WalkBudget) -> Bool {
        if node.domClassList.contains(Self.offscreenClass) { return false }
        if node.roleDescription?.lowercased() == Self.videoRenderRoleDescription { return false }
        if !budget.descendLeaves, let role = node.role, Self.leafRoles.contains(role) { return false }
        return true
    }

    private func title(of window: AXUIElement, deadline: Date) -> CallSpeakerReadPlan.TitleRead {
        if let issue = boundNextRead(on: window, deadline: deadline) {
            // A window closed mid-scan has no title to match: skip it.
            return issue == .ax(.invalidUIElement) ? .text("") : .failed(issue)
        }
        var titleRef: AnyObject?
        let status = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        return Self.titleValue(status: status, value: titleRef)
    }

    /// Native AX error decoding is separately testable without reading any app.
    /// A window destroyed mid-scan (`invalidUIElement`) reads as untitled.
    static func titleValue(status: AXError, value: AnyObject?) -> CallSpeakerReadPlan.TitleRead {
        switch status {
        case .success:
            if value == nil { return .text("") }
            if let text = value as? String { return .text(text) }
            return .failed(.unexpectedValue)
        case .noValue, .attributeUnsupported, .invalidUIElement:
            return .text("")
        default:
            return .failed(.ax(status))
        }
    }

    /// A windowless app (Zoom in the menu bar) answers `noValue`: no windows,
    /// a complete read. Any other failure leaves the app unexamined.
    static func windowListValue(status: AXError, value: AnyObject?) -> WindowListRead {
        switch status {
        case .success:
            if value == nil { return .windows([]) }
            if let windows = value as? [AXUIElement] { return .windows(windows) }
            return .failed(.unexpectedValue)
        case .noValue:
            return .windows([])
        default:
            return .failed(.ax(status))
        }
    }

    /// Indices into `attributes` of web-only attributes that native apps
    /// answer with placeholder errors (`failure`, `illegalArgument`).
    static let customAttributeIndices: Set<Int> = [
        attributes.firstIndex(of: domIdentifierAttribute)!,
        attributes.firstIndex(of: domClassListAttribute)!,
    ]

    /// The live walk uses this decoder before interpreting any batch values.
    static func batchReadOutcome(status: AXError, values: [AnyObject]?) -> ElementReadOutcome {
        guard status == .success else {
            return status == .invalidUIElement ? .skip(.ax(status)) : .truncate(.ax(status))
        }
        guard let values, values.count == attributes.count else { return .truncate(.unexpectedValue) }
        return elementReadOutcome(values)
    }

    /// Decodes the per-attribute error placeholders AX puts inside an
    /// otherwise successful batch read. Missing attributes are normal.
    /// - `cannotComplete` on any attribute: the element couldn't be read in
    ///   time, so the window is cut short.
    /// - `invalidUIElement`: the element was destroyed mid-walk; skip it.
    /// - Any other error on a custom DOM attribute: treated as absent.
    /// - Any other error on a standard attribute (role, title, children...):
    ///   that part of the window is unknown, so the window is cut short.
    static func elementReadOutcome(
        _ values: [AnyObject],
        customAttributeIndices: Set<Int> = CallSpeakerAXTreeReader.customAttributeIndices
    ) -> ElementReadOutcome {
        var destroyed = false
        var standardFailure: AXError?
        for (index, value) in values.enumerated() where CFGetTypeID(value) == AXValueGetTypeID() {
            let boxed = value as! AXValue
            guard AXValueGetType(boxed) == .axError else { continue }
            var error = AXError.success
            guard AXValueGetValue(boxed, .axError, &error) else {
                standardFailure = standardFailure ?? .failure
                continue
            }
            switch error {
            case .success, .noValue, .attributeUnsupported:
                continue
            case .cannotComplete:
                return .truncate(.ax(.cannotComplete))
            case .invalidUIElement:
                destroyed = true
            default:
                if !customAttributeIndices.contains(index) { standardFailure = standardFailure ?? error }
            }
        }
        if destroyed { return .skip(.ax(.invalidUIElement)) }
        if let standardFailure { return .truncate(.ax(standardFailure)) }
        return .usable
    }

    /// Bounds the next round trip on `element` by the messaging timeout and
    /// what is left of the deadline. Nil when bounded; otherwise why not.
    private func boundNextRead(on element: AXUIElement, deadline: Date) -> CallSpeakerScanIssue? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.005 else { return .deadline }
        let status = AXUIElementSetMessagingTimeout(element, Float(min(remaining, Self.messagingTimeout)))
        return status == .success ? nil : .ax(status)
    }
}

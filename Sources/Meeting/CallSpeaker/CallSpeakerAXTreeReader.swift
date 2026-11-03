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
//   60 per window. Running out marks the window truncated, which withholds it.
// - Up to 8 meeting windows per app. Slack: up to 32 windows sharing one
//   4000-node budget, huddle-titled windows first (a huddle can be in any).
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
    static let maxWindowsPerApp = 8
    static let maxSlackWindows = 32
    static let maxNodesPerWindow = 4000
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
        let deadline = Date().addingTimeInterval(Self.readDeadline)
        let ordered = CallSpeakerReadPlan.ordered(apps) { $0.host }
        var windows: [CallSpeakerWindowRead] = []
        for (index, app) in ordered.enumerated() {
            let now = Date()
            guard now < deadline else { break }
            let appDeadline = CallSpeakerReadPlan.appDeadline(now: now, pollDeadline: deadline, appsLeft: ordered.count - index)
            windows.append(contentsOf: meetingWindows(of: app, deadline: appDeadline))
        }
        return CallSpeakerReadResult(supportedAppRunning: true, windows: windows)
    }

    private func meetingWindows(of app: HostApp, deadline: Date) -> [CallSpeakerWindowRead] {
        let appElement = AXUIElementCreateApplication(app.pid)
        var windowsRef: AnyObject?
        guard setTimeout(on: appElement, deadline: deadline),
              AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return [] }

        // Titles first, so only meeting windows are walked.
        let isSlack = app.host == .slack
        var candidates: [(window: AXUIElement, match: CallSpeakerWindowMatch, huddle: Bool)] = []
        var titles: [String] = []
        for window in windows.prefix(isSlack ? Self.maxSlackWindows : Self.maxWindowsPerApp) {
            guard Date() < deadline else { break }
            let title = title(of: window, deadline: deadline) ?? ""
            guard let match = CallSpeakerWindowMatcher.match(title: title, host: app.host) else { continue }
            if isSlack { titles.append(title) }
            candidates.append((window, match, CallSpeakerWindowMatcher.isLikelyHuddleTitle(title)))
        }
        guard !candidates.isEmpty else { return [] }
        if isSlack {
            // Not in a likely huddle: no walk, and no AXManualAccessibility.
            guard CallSpeakerReadPlan.isSlackHuddleLikely(
                windowTitles: titles,
                holdsMicrophone: { isSlackHoldingMicrophone() }
            ) else { return [] }
            candidates.sort { $0.huddle && !$1.huddle }
        }

        if CallSpeakerApp.needsManualAccessibility(bundleID: app.bundleID),
           !manualAccessibilityPIDs.contains(app.pid),
           setTimeout(on: appElement, deadline: deadline) {
            AXUIElementSetAttributeValue(appElement, Self.manualAccessibilityAttribute as CFString, kCFBooleanTrue)
            manualAccessibilityPIDs.insert(app.pid)
        }

        var reads: [CallSpeakerWindowRead] = []
        // Slack windows share one node budget; other apps get one per window.
        var shared = WalkBudget(deadline: deadline, descendLeaves: true)
        for candidate in candidates {
            guard Date() < deadline else { break }
            var budget = isSlack ? shared : WalkBudget(deadline: deadline, descendLeaves: app.host != .zoom)
            let tree = walk(candidate.window, depth: 0, budget: &budget) ?? CallSpeakerAXNode()
            reads.append(CallSpeakerWindowRead(match: candidate.match, tree: tree, truncated: budget.truncated))
            if isSlack {
                shared.nodes = budget.nodes
                if budget.nodes >= Self.maxNodesPerWindow { break }
            }
        }
        return reads
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
        guard budget.nodes < Self.maxNodesPerWindow,
              setTimeout(on: element, deadline: budget.deadline) else {
            budget.truncated = true
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
        guard status == .success,
              let values = valuesRef as? [AnyObject],
              values.count == Self.attributes.count else {
            // A timeout means part of the window went unread.
            if status == .cannotComplete { budget.truncated = true }
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
            budget.truncated = true
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

    private func title(of window: AXUIElement, deadline: Date) -> String? {
        guard setTimeout(on: window, deadline: deadline) else { return nil }
        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
    }

    /// Bounds the next round trip on `element` by the messaging timeout and
    /// what is left of the deadline. False when the deadline has passed.
    private func setTimeout(on element: AXUIElement, deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.005 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(min(remaining, Self.messagingTimeout)))
        return true
    }
}

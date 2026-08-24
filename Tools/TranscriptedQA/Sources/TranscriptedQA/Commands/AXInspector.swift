import AppKit
import ApplicationServices
import Foundation

struct LaunchedApp {
    let process: Process
    let logURL: URL
}

func applyIsolatedLaunchEnvironment(_ environment: inout [String: String], isolatedHome: URL) {
    environment["HOME"] = isolatedHome.path
    environment["CFFIXED_USER_HOME"] = isolatedHome.path
    environment.removeValue(forKey: "__CFBundleIdentifier")
    environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
    environment["TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS"] = "1"
    environment["TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD"] = "1"
}

struct AXInspector {
    let root: AXUIElement

    func first(identifier: String, maxDepth: Int = 12, maxNodes: Int = 2_000) -> AXNode? {
        snapshotNodes(maxDepth: maxDepth, maxNodes: maxNodes).first { $0.observed.identifier == identifier }
    }

    func performPress(identifier: String, maxDepth: Int = 12, maxNodes: Int = 2_000) -> Bool {
        var queue: [(element: AXUIElement, depth: Int, ancestors: [AXUIElement])] = [(root, 0, [])]
        var visited = Set<CFHashCode>()
        var visitedCount = 0

        while !queue.isEmpty, visitedCount < maxNodes {
            let (element, depth, ancestors) = queue.removeFirst()
            let key = CFHash(element)
            if visited.contains(key) { continue }
            visited.insert(key)
            visitedCount += 1

            if observedElement(for: element).identifier == identifier {
                for candidate in [element] + ancestors.reversed() {
                    if Self.performPress(candidate) {
                        return true
                    }
                }
                return false
            }

            guard depth < maxDepth else { continue }
            for child in children(of: element) {
                queue.append((child, depth + 1, ancestors + [element]))
            }
        }

        return false
    }

    func selectRow(identifier: String, maxDepth: Int = 12, maxNodes: Int = 2_000) -> Bool {
        var queue: [(element: AXUIElement, depth: Int, ancestors: [AXUIElement])] = [(root, 0, [])]
        var visited = Set<CFHashCode>()
        var visitedCount = 0

        while !queue.isEmpty, visitedCount < maxNodes {
            let (element, depth, ancestors) = queue.removeFirst()
            let key = CFHash(element)
            if visited.contains(key) { continue }
            visited.insert(key)
            visitedCount += 1

            if observedElement(for: element).identifier == identifier {
                for candidate in [element] + ancestors.reversed() {
                    guard string(candidate, kAXRoleAttribute as String) == kAXRowRole as String else {
                        continue
                    }
                    if Self.select(candidate) {
                        return true
                    }
                }
                return false
            }

            guard depth < maxDepth else { continue }
            for child in children(of: element) {
                queue.append((child, depth + 1, ancestors + [element]))
            }
        }

        return false
    }

    func performPressOrClick(identifier: String, maxDepth: Int = 12, maxNodes: Int = 2_000) -> Bool {
        if performPress(identifier: identifier, maxDepth: maxDepth, maxNodes: maxNodes) {
            return true
        }
        guard let frame = first(identifier: identifier, maxDepth: maxDepth, maxNodes: maxNodes)?.observed.frame else {
            return false
        }
        return Self.performClick(frame: frame)
    }

    func snapshot(maxDepth: Int = 10, maxNodes: Int = 2_000) -> [AXObservedElement] {
        snapshotNodes(maxDepth: maxDepth, maxNodes: maxNodes).map(\.observed)
    }

    func snapshotNodes(maxDepth: Int = 10, maxNodes: Int = 2_000) -> [AXNode] {
        var output: [AXNode] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = Set<CFHashCode>()

        while !queue.isEmpty, output.count < maxNodes {
            let (element, depth) = queue.removeFirst()
            let key = CFHash(element)
            if visited.contains(key) { continue }
            visited.insert(key)

            output.append(AXNode(element: element, observed: observedElement(for: element)))
            guard depth < maxDepth else { continue }

            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }

        return output
    }

    static func performPress(_ element: AXUIElement) -> Bool {
        var actionsValue: CFArray?
        let actionError = AXUIElementCopyActionNames(element, &actionsValue)
        let actions = (actionsValue as? [String]) ?? []
        guard actionError == .success, actions.contains(kAXPressAction as String) else {
            return false
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func select(_ element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedAttribute as CFString,
            &isSettable
        ) == .success, isSettable.boolValue else {
            return false
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    static func performClick(frame: AXFrame) -> Bool {
        let point = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        let attributes = [
            kAXWindowsAttribute as String,
            kAXChildrenAttribute as String,
            kAXVisibleChildrenAttribute as String,
            kAXMenuBarAttribute as String,
            "AXChildrenInNavigationOrder",
            "AXExtrasMenuBar",
            "AXContents",
        ]

        var children: [AXUIElement] = []
        for attribute in attributes {
            children.append(contentsOf: elements(from: value(element, attribute)))
        }
        return children
    }

    private func observedElement(for element: AXUIElement) -> AXObservedElement {
        AXObservedElement(
            identifier: string(element, kAXIdentifierAttribute as String),
            title: string(element, kAXTitleAttribute as String),
            role: string(element, kAXRoleAttribute as String),
            description: string(element, kAXDescriptionAttribute as String),
            help: string(element, kAXHelpAttribute as String),
            isEnabled: bool(element, kAXEnabledAttribute as String),
            frame: frame(element)
        )
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        if let value = value(element, attribute) as? Bool {
            return value
        }
        if let value = value(element, attribute) as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    private func frame(_ element: AXUIElement) -> AXFrame? {
        var origin = CGPoint.zero
        var size = CGSize.zero

        if let positionValue = value(element, kAXPositionAttribute as String),
           CFGetTypeID(positionValue) == AXValueGetTypeID() {
            AXValueGetValue((positionValue as! AXValue), .cgPoint, &origin)
        } else {
            return nil
        }

        if let sizeValue = value(element, kAXSizeAttribute as String),
           CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            AXValueGetValue((sizeValue as! AXValue), .cgSize, &size)
        } else {
            return nil
        }

        return AXFrame(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    private func elements(from value: CFTypeRef?) -> [AXUIElement] {
        guard let value else { return [] }
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return [value as! AXUIElement]
        }
        return (value as? [AXUIElement]) ?? []
    }
}

struct AXNode {
    let element: AXUIElement
    let observed: AXObservedElement
}

struct AXObservedElement: Codable, Equatable {
    let identifier: String?
    let title: String?
    let role: String?
    let description: String?
    let help: String?
    let isEnabled: Bool?
    let frame: AXFrame?
}

struct AXFrame: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

// SecureEventInputSource.swift
// Live Carbon / IOKit / AppKit adapters behind the protocols the warning
// policy and monitor use. Fast tests inject fakes and never call this file's
// live types; the parser for IOConsoleUsers lives on the policy.

import AppKit
import Carbon
import Darwin
import Foundation
import IOKit

protocol SecureEventInputReading: AnyObject {
    func isEnabled() -> Bool
    func ownerProcessID() -> Int32?
}

protocol SecureEventInputProcessNaming {
    func runningApplicationDisplayName(forProcessID pid: Int32) -> String?
    func processName(forProcessID pid: Int32) -> String?
}

final class LiveSecureEventInputSource: SecureEventInputReading {
    /// Carbon's public on/off. While this is true, session-level event taps
    /// do not receive standard keystrokes (Apple TN2150).
    func isEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    func ownerProcessID() -> Int32? {
        SecureEventInputIORegistry.ownerProcessID()
    }
}

struct LiveSecureEventInputProcessNamer: SecureEventInputProcessNaming {
    func runningApplicationDisplayName(forProcessID pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
    }

    func processName(forProcessID pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

enum SecureEventInputIORegistry {
    /// Public IOKit only: IOResources holds the `IOConsoleUsers` array that
    /// `ioreg` prints. Root is a fallback if that node is missing the property.
    static func ownerProcessID() -> Int32? {
        if let users = consoleUsers(fromServiceNamed: "IOResources")
            ?? consoleUsersFromRoot(),
           let pid = SecureKeyboardEntryWarningPolicy.ownerProcessID(fromConsoleUsers: users) {
            return pid
        }
        return nil
    }

    private static func consoleUsers(fromServiceNamed name: String) -> [[String: Any]]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return consoleUsers(from: service)
    }

    private static func consoleUsersFromRoot() -> [[String: Any]]? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return consoleUsers(from: root)
    }

    private static func consoleUsers(from entry: io_registry_entry_t) -> [[String: Any]]? {
        guard let property = IORegistryEntryCreateCFProperty(
            entry,
            SecureEventInputRegistryKeys.consoleUsers as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }
        return dictionaries(from: property)
    }

    static func dictionaries(from property: CFTypeRef) -> [[String: Any]]? {
        if let users = property as? [[String: Any]] {
            return users
        }
        guard let array = property as? [Any] else { return nil }
        return array.compactMap { $0 as? [String: Any] }
    }
}

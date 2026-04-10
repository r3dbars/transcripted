// DictationSessionTimeout.swift
// Tracks dictation session timeout against active system uptime so Mac sleep
// does not consume the user's remaining recording window.

import Foundation

struct DictationSessionTimeout {
    private(set) var deadlineUptime: TimeInterval?
    let timeoutInterval: TimeInterval

    init(timeoutInterval: TimeInterval) {
        self.timeoutInterval = timeoutInterval
    }

    mutating func start(at uptime: TimeInterval) {
        deadlineUptime = uptime + timeoutInterval
    }

    mutating func clear() {
        deadlineUptime = nil
    }

    func remaining(at uptime: TimeInterval) -> TimeInterval? {
        guard let deadlineUptime else { return nil }
        return max(0, deadlineUptime - uptime)
    }

    func isExpired(at uptime: TimeInterval) -> Bool {
        guard let deadlineUptime else { return false }
        return uptime >= deadlineUptime
    }
}

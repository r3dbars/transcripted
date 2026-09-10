import Foundation

/// App-generated identity only. Never derived from hardware, account, email, or content.
enum InstallIdentity {
    static let storageKey = "observability-anonymous-analytics-id"
    private static let firstLaunchKey = "observability-first-launch-day"
    private static let lock = NSLock()

    static func id(userDefaults: UserDefaults = .standard) -> String {
        lock.lock()
        defer { lock.unlock() }
        // Preserve the existing PostHog UUID byte-for-byte so upgrades do not split people.
        if let existing = userDefaults.string(forKey: storageKey), UUID(uuidString: existing) != nil {
            return existing
        }
        let id = UUID().uuidString
        userDefaults.set(id, forKey: storageKey)
        return id
    }

    static func firstLaunchDay(userDefaults: UserDefaults = .standard, now: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = userDefaults.string(forKey: firstLaunchKey),
           existing.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return existing
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: now)
        userDefaults.set(day, forKey: firstLaunchKey)
        return day
    }

    static func traits(userDefaults: UserDefaults = .standard, now: Date = Date()) -> [String: String] {
        [
            "analytics_opt_in": "true",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build_revision": AnalyticsRuntimeConfiguration.buildRevision(),
            "os_major": "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)",
            "install_channel": AnalyticsRuntimeConfiguration.buildChannel(),
            // For upgrades this is the first observed day with this instrumentation.
            "first_launch_at": firstLaunchDay(userDefaults: userDefaults, now: now),
        ]
    }
}

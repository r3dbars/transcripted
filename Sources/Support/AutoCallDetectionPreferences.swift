// Support/AutoCallDetectionPreferences.swift
// Preference flag for ad-hoc call detection via mic activity.
//
// When enabled, MicActivityMonitor watches which process holds the microphone
// input and the meeting-prompt detector offers to record when a call starts —
// including a spontaneous Google Meet with no calendar invite. See
// docs/auto-call-detection-spec.md.
//
// Default ON (product decision 2026-06-14). Everything
// stays on-device — we read which app holds the mic (metadata), never audio —
// but it is still surfaced behind a clear Settings toggle so it can be turned off.

import Foundation

enum AutoCallDetectionPreferences {

    static let enabledKey = "auto-call-detection-enabled"

    private static let standardCache = PreferenceCache(
        userDefaults: .standard,
        notificationCenter: .default
    )

    /// In-memory cache for `UserDefaults.standard` so hot-path checks (such as
    /// `MicActivityMonitor.scanAndEmit` on the main actor every 5 s) never block
    /// on a stalled `cfprefsd` XPC read. External writes refresh off-main via
    /// `UserDefaults.didChangeNotification`, while explicit writes through
    /// `setEnabled` update the cached value synchronously.
    final class PreferenceCache: @unchecked Sendable {
        private let lock = NSLock()
        private let userDefaults: UserDefaults
        private let notificationCenter: NotificationCenter
        private let customReader: (@Sendable () -> Bool)?
        private let refreshQueue: DispatchQueue
        private var cachedValue: Bool?
        private var generation: UInt64 = 0
        private var directWriteDepth = 0
        private var observerTokens: [NSObjectProtocol] = []

        init(
            userDefaults: UserDefaults,
            notificationCenter: NotificationCenter = .default,
            readValue: (@Sendable () -> Bool)? = nil
        ) {
            self.userDefaults = userDefaults
            self.notificationCenter = notificationCenter
            self.customReader = readValue
            self.refreshQueue = DispatchQueue(
                label: "com.transcripted.auto-call-detection-prefs-cache",
                qos: .utility
            )

            observerTokens.append(notificationCenter.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: userDefaults,
                queue: nil
            ) { [weak self] _ in
                self?.scheduleBackgroundRefresh()
            })
            observerTokens.append(notificationCenter.addObserver(
                forName: .autoCallDetectionPrefsDidChange,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.refreshImmediatelyIfExternal()
            })
        }

        deinit {
            for token in observerTokens {
                notificationCenter.removeObserver(token)
            }
        }

        func isEnabled() -> Bool {
            let startGeneration: UInt64
            lock.lock()
            if let cached = cachedValue {
                lock.unlock()
                return cached
            }
            startGeneration = generation
            lock.unlock()

            let fresh = readFromBackingStore()
            lock.lock()
            if generation == startGeneration && cachedValue == nil {
                cachedValue = fresh
            }
            let result = cachedValue ?? fresh
            lock.unlock()
            return result
        }

        func warmAsync() {
            let startGeneration: UInt64
            lock.lock()
            if cachedValue != nil {
                lock.unlock()
                return
            }
            startGeneration = generation
            lock.unlock()

            refreshQueue.async { [weak self] in
                guard let self else { return }
                let fresh = self.readFromBackingStore()
                self.lock.lock()
                if self.generation == startGeneration && self.cachedValue == nil {
                    self.cachedValue = fresh
                }
                self.lock.unlock()
            }
        }

        func updateForDirectWrite(_ enabled: Bool, perform: () -> Void) {
            lock.lock()
            generation &+= 1
            cachedValue = enabled
            directWriteDepth += 1
            lock.unlock()

            defer {
                lock.lock()
                directWriteDepth -= 1
                lock.unlock()
            }
            perform()
        }

        func waitForPendingRefreshForTesting() {
            refreshQueue.sync {}
        }

        private func scheduleBackgroundRefresh() {
            let scheduledGeneration: UInt64
            lock.lock()
            if directWriteDepth > 0 {
                lock.unlock()
                return
            }
            scheduledGeneration = generation
            lock.unlock()

            refreshQueue.async { [weak self] in
                guard let self else { return }
                let fresh = self.readFromBackingStore()
                self.lock.lock()
                if self.generation == scheduledGeneration {
                    self.cachedValue = fresh
                }
                self.lock.unlock()
            }
        }

        private func refreshImmediatelyIfExternal() {
            lock.lock()
            if directWriteDepth > 0 {
                lock.unlock()
                return
            }
            lock.unlock()

            let fresh = readFromBackingStore()
            lock.lock()
            generation &+= 1
            cachedValue = fresh
            lock.unlock()
        }

        private func readFromBackingStore() -> Bool {
            if let customReader {
                return customReader()
            }
            return AutoCallDetectionPreferences.readUncached(from: userDefaults)
        }
    }

    /// Whether mic-activity call detection runs. Defaults to true: until the user
    /// first toggles it the key is absent, and absence means on.
    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults === UserDefaults.standard {
            return standardCache.isEnabled()
        }
        return readUncached(from: userDefaults)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        if userDefaults === UserDefaults.standard {
            standardCache.updateForDirectWrite(enabled) {
                persistAndNotify(enabled, userDefaults: userDefaults)
            }
            return
        }
        persistAndNotify(enabled, userDefaults: userDefaults)
    }

    /// Warms the `.standard` cache off the main thread so even the first
    /// hot-path read from `MicActivityMonitor` does not hit `cfprefsd`.
    static func warmStandardCache() {
        standardCache.warmAsync()
    }

    static func readUncached(from userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: enabledKey) != nil else { return true }
        return userDefaults.bool(forKey: enabledKey)
    }

    private static func persistAndNotify(_ enabled: Bool, userDefaults: UserDefaults) {
        userDefaults.set(enabled, forKey: enabledKey)
        NotificationCenter.default.post(name: .autoCallDetectionPrefsDidChange, object: nil)
    }
}

extension Notification.Name {
    static let autoCallDetectionPrefsDidChange = Notification.Name("autoCallDetectionPrefsDidChange")
}

import Foundation

func testAutoCallDetectionPreferences() {
    runSuite("AutoCallDetectionPreferences defaults to enabled") {
        let (defaults, suiteName) = makeAutoCallDetectionDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(
            AutoCallDetectionPreferences.isEnabled(userDefaults: defaults),
            "ad-hoc call detection should be on for new installs (default ON)"
        )
    }

    runSuite("AutoCallDetectionPreferences persists disabled and re-enabled states") {
        let (defaults, suiteName) = makeAutoCallDetectionDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AutoCallDetectionPreferences.setEnabled(false, userDefaults: defaults)
        assertFalse(
            AutoCallDetectionPreferences.isEnabled(userDefaults: defaults),
            "an explicit opt-out should round-trip and stay off"
        )

        AutoCallDetectionPreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(
            AutoCallDetectionPreferences.isEnabled(userDefaults: defaults),
            "an explicit opt-in should round-trip back on"
        )
    }

    runSuite("AutoCallDetectionPreferences uses a stable storage key") {
        assertEqual(
            AutoCallDetectionPreferences.enabledKey,
            "auto-call-detection-enabled",
            "storage key must stay stable across releases"
        )
    }

    runSuite("AutoCallDetectionPreferences.PreferenceCache serves hot-path reads from memory") {
        let (defaults, suiteName) = makeAutoCallDetectionDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let center = NotificationCenter()
        let readCounter = LockedCounter()
        let backingValue = LockedBool(true)
        let cache = AutoCallDetectionPreferences.PreferenceCache(
            userDefaults: defaults,
            notificationCenter: center,
            readValue: {
                readCounter.increment()
                return backingValue.value
            }
        )

        assertTrue(cache.isEnabled(), "first read loads the initial preference value")
        assertTrue(cache.isEnabled(), "second read returns the cached value")
        assertTrue(cache.isEnabled(), "third read returns the cached value")
        assertEqual(readCounter.value, 1, "repeated hot-path reads must hit the backing store only once")

        cache.updateForDirectWrite(false) {
            backingValue.value = false
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
            center.post(name: .autoCallDetectionPrefsDidChange, object: nil)
        }
        cache.waitForPendingRefreshForTesting()
        assertFalse(cache.isEnabled(), "direct write updates the cache synchronously")
        assertEqual(readCounter.value, 1, "direct write must not re-read cfprefsd synchronously")

        backingValue.value = true
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        cache.waitForPendingRefreshForTesting()
        assertTrue(cache.isEnabled(), "external UserDefaults changes refresh the cache asynchronously")
        assertEqual(readCounter.value, 2, "external didChange triggers one background refresh")

        backingValue.value = false
        center.post(name: .autoCallDetectionPrefsDidChange, object: nil)
        assertFalse(cache.isEnabled(), "external autoCallDetectionPrefsDidChange (e.g. volatile domain) refreshes immediately")
        assertEqual(readCounter.value, 3, "external prefs notification performs one sync refresh")
    }

    runSuite("AutoCallDetectionPreferences.PreferenceCache warms off the calling thread") {
        let (defaults, suiteName) = makeAutoCallDetectionDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let center = NotificationCenter()
        let readCounter = LockedCounter()
        let readOnMain = LockedBool(true)
        let cache = AutoCallDetectionPreferences.PreferenceCache(
            userDefaults: defaults,
            notificationCenter: center,
            readValue: {
                readCounter.increment()
                readOnMain.value = Thread.isMainThread
                return false
            }
        )

        cache.warmAsync()
        cache.waitForPendingRefreshForTesting()

        assertFalse(readOnMain.value, "warming the cache must read UserDefaults off the main thread")
        assertFalse(cache.isEnabled(), "subsequent hot-path read sees the warmed value")
        assertEqual(readCounter.value, 1, "hot-path read after warming must not hit UserDefaults again")
    }

    runSuite("AutoCallDetectionPreferences.PreferenceCache discards stale external refresh after overlapping direct write") {
        let (defaults, suiteName) = makeAutoCallDetectionDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let center = NotificationCenter()
        let readStarted = DispatchSemaphore(value: 0)
        let allowReadFinish = DispatchSemaphore(value: 0)
        let shouldBlockNextRead = LockedBool(false)
        let cache = AutoCallDetectionPreferences.PreferenceCache(
            userDefaults: defaults,
            notificationCenter: center,
            readValue: {
                if shouldBlockNextRead.value {
                    shouldBlockNextRead.value = false
                    readStarted.signal()
                    allowReadFinish.wait()
                    return true
                }
                return true
            }
        )

        assertTrue(cache.isEnabled(), "seed initial cache")
        shouldBlockNextRead.value = true

        let refreshDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            center.post(name: .autoCallDetectionPrefsDidChange, object: nil)
            refreshDone.signal()
        }

        readStarted.wait()
        // A direct write arrives while the external refresh is mid-read.
        cache.updateForDirectWrite(false) {}
        allowReadFinish.signal()
        refreshDone.wait()

        assertFalse(
            cache.isEnabled(),
            "a stale external refresh that started before a direct write must not overwrite the newer cached value"
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ initial: Bool) {
        storage = initial
    }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private func makeAutoCallDetectionDefaults() -> (UserDefaults, String) {
    let suiteName = "AutoCallDetectionPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

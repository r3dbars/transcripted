import Foundation

/// Counts UserDefaults.didChangeNotification posts for one defaults object.
/// Every write posts to every observer in the app, so a write that changes
/// nothing still wakes up every settings screen and controller listening.
private final class DefaultsChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var posts = 0
    private var token: NSObjectProtocol?

    init(watching defaults: UserDefaults) {
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: nil
        ) { [weak self] _ in
            self?.increment()
        }
    }

    private func increment() {
        lock.lock(); posts += 1; lock.unlock()
    }

    /// Posts seen since the last call.
    func take() -> Int {
        lock.lock(); defer { lock.unlock() }
        let seen = posts
        posts = 0
        return seen
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

func testUserDefaultsChangeOnlyWrites() {
    func withThrowawayDefaults(_ body: (UserDefaults, DefaultsChangeCounter) -> Void) {
        let suiteName = "transcripted-tests.change-only-writes.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assertTrue(false, "a throwaway defaults suite opens")
            return
        }
        let counter = DefaultsChangeCounter(watching: defaults)
        defer {
            counter.stop()
            defaults.removePersistentDomain(forName: suiteName)
        }
        body(defaults, counter)
    }

    runSuite("Writing a value a default already holds posts no change") {
        withThrowawayDefaults { defaults, counter in
            defaults.set(true, forKey: "flag")
            assertTrue(counter.take() > 0, "a plain write posts, so the counter is listening")

            defaults.setIfChanged(true, forKey: "flag")
            assertEqual(counter.take(), 0, "writing true over true posts nothing")
            assertEqual(defaults.object(forKey: "flag") as? Bool, true, "and the value is still true")

            defaults.setIfChanged(false, forKey: "flag")
            assertTrue(counter.take() > 0, "a real change still posts")
            assertEqual(defaults.object(forKey: "flag") as? Bool, false, "and stores false")

            defaults.setIfChanged(false, forKey: "flag")
            assertEqual(counter.take(), 0, "writing false over false posts nothing")
            assertEqual(defaults.object(forKey: "flag") as? Bool, false, "false stays stored")

            // bool(forKey:) reads a missing key as false, so false into a
            // missing key is the case a lazy comparison gets wrong.
            assertNil(defaults.object(forKey: "fresh-false"), "the key starts missing")
            defaults.setIfChanged(false, forKey: "fresh-false")
            assertEqual(defaults.object(forKey: "fresh-false") as? Bool, false, "a first write of false is stored, not skipped")
            assertTrue(counter.take() > 0, "and posts, because something changed")

            assertNil(defaults.object(forKey: "fresh-true"), "the key starts missing")
            defaults.setIfChanged(true, forKey: "fresh-true")
            assertEqual(defaults.object(forKey: "fresh-true") as? Bool, true, "a first write of true is stored")
            assertTrue(counter.take() > 0, "and posts")
            defaults.setIfChanged(true, forKey: "fresh-true")
            assertEqual(counter.take(), 0, "the second identical write posts nothing")
        }
    }

    runSuite("Removing a missing key posts nothing, removing a stored key removes it") {
        withThrowawayDefaults { defaults, counter in
            assertNil(defaults.object(forKey: "never-set"), "the key starts missing")
            defaults.removeObjectIfPresent(forKey: "never-set")
            assertEqual(counter.take(), 0, "removing a missing key posts nothing")
            assertNil(defaults.object(forKey: "never-set"), "and it's still missing")

            defaults.set(false, forKey: "stored")
            _ = counter.take()
            defaults.removeObjectIfPresent(forKey: "stored")
            assertNil(defaults.object(forKey: "stored"), "a stored false is removed, not mistaken for missing")
            assertTrue(counter.take() > 0, "and the removal posts")

            defaults.set(true, forKey: "stored-true")
            _ = counter.take()
            defaults.removeObjectIfPresent(forKey: "stored-true")
            assertNil(defaults.object(forKey: "stored-true"), "a stored true is removed")
            assertTrue(counter.take() > 0, "and the removal posts")

            defaults.removeObjectIfPresent(forKey: "stored-true")
            assertEqual(counter.take(), 0, "removing it a second time posts nothing")
        }
    }
}

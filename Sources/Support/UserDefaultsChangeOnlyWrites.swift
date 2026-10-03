// UserDefaultsChangeOnlyWrites.swift
// UserDefaults writes that skip themselves when nothing would change.
//
// Every write posts UserDefaults.didChangeNotification to every observer in
// the app, even when the stored value is the same, and removing a missing
// key posts too. Code that refreshes a cached flag on every window
// activation or meeting start should only write a real change.

import Foundation

extension UserDefaults {
    /// Writes `value` only when it differs from what's stored.
    func setIfChanged(_ value: Bool, forKey key: String) {
        guard object(forKey: key) as? Bool != value else { return }
        set(value, forKey: key)
    }

    /// Removes `key` only when something is stored there.
    func removeObjectIfPresent(forKey key: String) {
        guard object(forKey: key) != nil else { return }
        removeObject(forKey: key)
    }
}

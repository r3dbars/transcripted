import Foundation

extension UserDefaults {
    /// Writes only when the stored value differs. Every write posts
    /// `UserDefaults.didChangeNotification` to the whole app, so state
    /// refreshed on each app activation shouldn't rewrite unchanged values.
    func setIfChanged(_ value: Bool, forKey key: String) {
        guard object(forKey: key) as? Bool != value else { return }
        set(value, forKey: key)
    }

    /// Removes the key only when it's present, for the same reason.
    func removeIfPresent(forKey key: String) {
        guard object(forKey: key) != nil else { return }
        removeObject(forKey: key)
    }
}

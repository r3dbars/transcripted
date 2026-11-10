import Foundation

/// A separate, non-persistent preference store for each test fixture. Every
/// supported accessor stays in memory even through a UserDefaults reference.
final class WritingTestDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var registered: [String: Any]

    init(registered: [String: Any] = [:]) {
        self.registered = registered
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key] ?? registered[key]
    }

    override func set(_ value: Any?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: URL?, forKey key: String) {
        if let value { set(value as Any, forKey: key) }
        else { removeObject(forKey: key) }
    }

    override func removeObject(forKey key: String) { set(nil as Any?, forKey: key) }
    override func bool(forKey key: String) -> Bool {
        if let number = object(forKey: key) as? NSNumber { return number.boolValue }
        return (object(forKey: key) as? NSString)?.boolValue ?? false
    }
    override func integer(forKey key: String) -> Int {
        if let number = object(forKey: key) as? NSNumber { return number.intValue }
        return (object(forKey: key) as? NSString)?.integerValue ?? 0
    }
    override func float(forKey key: String) -> Float {
        if let number = object(forKey: key) as? NSNumber { return number.floatValue }
        return (object(forKey: key) as? NSString)?.floatValue ?? 0
    }
    override func double(forKey key: String) -> Double {
        if let number = object(forKey: key) as? NSNumber { return number.doubleValue }
        return (object(forKey: key) as? NSString)?.doubleValue ?? 0
    }
    override func string(forKey key: String) -> String? {
        if let string = object(forKey: key) as? String { return string }
        return (object(forKey: key) as? NSNumber)?.stringValue
    }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func url(forKey key: String) -> URL? { object(forKey: key) as? URL }

    override func register(defaults: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        registered.merge(defaults) { _, new in new }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return registered.merging(values) { _, new in new }
    }

    override func removePersistentDomain(forName domainName: String) {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll()
    }

    override func synchronize() -> Bool { true }
}

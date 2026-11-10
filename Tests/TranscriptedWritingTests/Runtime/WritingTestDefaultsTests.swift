import Foundation
import Testing

@Suite("Writing fixture preferences")
struct WritingTestDefaultsTests {
    @Test("Typed access through UserDefaults stays in each fixture's memory")
    func typedAccessIsIsolated() {
        let first: UserDefaults = WritingTestDefaults()
        let second: UserDefaults = WritingTestDefaults()
        first.set(true, forKey: "flag")
        first.set(7, forKey: "count")
        first.set(Float(1.5), forKey: "float")
        first.set(2.5, forKey: "double")
        first.set("value", forKey: "string")
        first.set(["one", "two"], forKey: "array")
        first.set(["nested": "value"], forKey: "dictionary")
        first.set(Data([1, 2]), forKey: "data")
        let url = URL(fileURLWithPath: "/synthetic-fixture")
        first.set(url, forKey: "url")

        #expect(first.bool(forKey: "flag"))
        #expect(first.integer(forKey: "count") == 7)
        #expect(first.float(forKey: "float") == 1.5)
        #expect(first.double(forKey: "double") == 2.5)
        #expect(first.string(forKey: "string") == "value")
        #expect(first.stringArray(forKey: "array") == ["one", "two"])
        #expect(first.array(forKey: "array") as? [String] == ["one", "two"])
        #expect(first.dictionary(forKey: "dictionary") as? [String: String] == ["nested": "value"])
        #expect(first.data(forKey: "data") == Data([1, 2]))
        #expect(first.url(forKey: "url") == url)
        #expect(first.object(forKey: "string") as? String == "value")
        #expect(second.dictionaryRepresentation().isEmpty)
        #expect(!second.bool(forKey: "flag"))
        #expect(second.integer(forKey: "count") == 0)
        #expect(first.synchronize())
        #expect(second.dictionaryRepresentation().isEmpty)
    }

    @Test("Registration and cleanup never escape the fixture")
    func removalRestoresRegisteredValues() {
        let defaults: UserDefaults = WritingTestDefaults(registered: ["key": "registered"])
        defaults.register(defaults: ["other": "fallback"])
        defaults.set("stored", forKey: "key")
        #expect(defaults.string(forKey: "key") == "stored")
        defaults.removeObject(forKey: "key")
        #expect(defaults.string(forKey: "key") == "registered")
        defaults.set(URL(fileURLWithPath: "/synthetic"), forKey: "url")
        defaults.set(nil as URL?, forKey: "url")
        #expect(defaults.object(forKey: "url") == nil)
        defaults.set(1, forKey: "count")
        defaults.removePersistentDomain(forName: "synthetic-fixture")
        #expect(defaults.dictionaryRepresentation() as? [String: String]
            == ["key": "registered", "other": "fallback"])
    }
}

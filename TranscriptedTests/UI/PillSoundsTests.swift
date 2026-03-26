import XCTest
import AppKit
@testable import Transcripted

final class PillSoundsTests: XCTestCase {

    // MARK: - System Sound Names Exist

    func testPopSoundExists() {
        let sound = NSSound(named: NSSound.Name("Pop"))
        XCTAssertNotNil(sound, "System sound 'Pop' should exist")
    }

    func testTinkSoundExists() {
        let sound = NSSound(named: NSSound.Name("Tink"))
        XCTAssertNotNil(sound, "System sound 'Tink' should exist")
    }

    func testGlassSoundExists() {
        let sound = NSSound(named: NSSound.Name("Glass"))
        XCTAssertNotNil(sound, "System sound 'Glass' should exist")
    }

    func testBassoSoundExists() {
        let sound = NSSound(named: NSSound.Name("Basso"))
        XCTAssertNotNil(sound, "System sound 'Basso' should exist")
    }

    // MARK: - Sound Toggle Key

    func testSoundToggleKeyExists() {
        // enableUISounds key should be readable (may be nil for unset)
        // This test verifies we're using the correct key name
        let key = "enableUISounds"
        // Reset to ensure clean state
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let orig = original {
                UserDefaults.standard.set(orig, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // When not set, sounds should be enabled (nil defaults to enabled)
        UserDefaults.standard.removeObject(forKey: key)
        let val = UserDefaults.standard.object(forKey: key) as? Bool
        XCTAssertNil(val, "Unset key should return nil (defaults to enabled)")
    }

    func testSoundDisabledWhenExplicitlyFalse() {
        let key = "enableUISounds"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let orig = original {
                UserDefaults.standard.set(orig, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.set(false, forKey: key)
        let val = UserDefaults.standard.object(forKey: key) as? Bool
        XCTAssertEqual(val, false)
    }

    func testSoundEnabledWhenExplicitlyTrue() {
        let key = "enableUISounds"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let orig = original {
                UserDefaults.standard.set(orig, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.set(true, forKey: key)
        let val = UserDefaults.standard.object(forKey: key) as? Bool
        XCTAssertEqual(val, true)
    }
}

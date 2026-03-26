import XCTest
@testable import Transcripted

@available(macOS 14.0, *)
final class SpeakerProfileMergerTests: XCTestCase {

    // MARK: - Name Variant Matching (static, no DB needed)

    func testNameVariantMikeAndMichael() {
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Mike", "Michael"))
        XCTAssertTrue(SpeakerDatabase.areNameVariants("michael", "mike"))
    }

    func testNameVariantNateAndNathan() {
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Nate", "Nathan"))
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Nathaniel", "Nate"))
    }

    func testNameVariantDaveAndDavid() {
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Dave", "David"))
    }

    func testNameVariantAlexAndAlexander() {
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Alex", "Alexander"))
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Alex", "Alexandra"))
    }

    func testNameVariantDanAndDaniel() {
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Dan", "Daniel"))
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Danny", "Daniel"))
    }

    func testNameVariantMattAndMatthew() {
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Matt", "Matthew"))
    }

    func testNameVariantChrisAndChristopher() {
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Chris", "Christopher"))
    }

    func testNameVariantNickAndNicholas() {
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Nick", "Nicholas"))
    }

    func testNameVariantBobAndRobert() {
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Bob", "Robert"))
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Rob", "Robert"))
    }

    func testNameVariantSubstringMatch() {
        // "Marques Brownlee" contains "Marques"
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Marques Brownlee", "Marques"))
    }

    func testNameVariantExactCaseInsensitive() {
        XCTAssertTrue(SpeakerDatabase.areNameVariants("SARAH", "sarah"))
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Sarah", "SARAH"))
    }

    func testNameVariantNoMatchDifferentNames() {
        XCTAssertFalse(SpeakerDatabase.areNameVariants("Alice", "Bob"))
        XCTAssertFalse(SpeakerDatabase.areNameVariants("Sarah", "Mike"))
    }

    func testNameVariantEmptyStrings() {
        XCTAssertFalse(SpeakerDatabase.areNameVariants("", ""))
        XCTAssertFalse(SpeakerDatabase.areNameVariants("Alice", ""))
        XCTAssertFalse(SpeakerDatabase.areNameVariants("", "Bob"))
    }

    func testNameVariantSymmetric() {
        // Order shouldn't matter
        XCTAssertEqual(
            SpeakerDatabase.areNameVariants("Mike", "Michael"),
            SpeakerDatabase.areNameVariants("Michael", "Mike")
        )
        XCTAssertEqual(
            SpeakerDatabase.areNameVariants("Bob", "Robert"),
            SpeakerDatabase.areNameVariants("Robert", "Bob")
        )
    }
}

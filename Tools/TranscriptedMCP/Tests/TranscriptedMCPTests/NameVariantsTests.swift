import XCTest
@testable import transcripted_mcp

final class NameVariantsTests: XCTestCase {
    func testExpandMike() {
        let expanded = NameVariants.expandName("Mike")
        XCTAssertTrue(expanded.contains("michael"))
        XCTAssertTrue(expanded.contains("mike"))
        XCTAssertTrue(expanded.contains("mikey"))
    }

    func testExpandWithLastName() {
        let expanded = NameVariants.expandName("Mike Smith")
        XCTAssertTrue(expanded.contains("michael smith"))
        XCTAssertTrue(expanded.contains("mike smith"))
        XCTAssertTrue(expanded.contains("michael"))
    }

    func testExpandUnknownName() {
        let expanded = NameVariants.expandName("Zara")
        XCTAssertEqual(expanded, ["zara"])
    }

    func testExpandEmptyString() {
        let expanded = NameVariants.expandName("")
        XCTAssertTrue(expanded.isEmpty)
    }

    func testExpandWhitespaceOnly() {
        let expanded = NameVariants.expandName("   ")
        XCTAssertTrue(expanded.isEmpty)
    }

    func testAreVariantsSymmetric() {
        XCTAssertEqual(
            NameVariants.areNameVariants("Mike", "Michael"),
            NameVariants.areNameVariants("Michael", "Mike")
        )
    }

    func testAreVariantsTrue() {
        XCTAssertTrue(NameVariants.areNameVariants("Mike", "Michael"))
        XCTAssertTrue(NameVariants.areNameVariants("Jen", "Jennifer"))
        XCTAssertTrue(NameVariants.areNameVariants("Bob", "Robert"))
    }

    func testAreVariantsFalse() {
        XCTAssertFalse(NameVariants.areNameVariants("Mike", "Jennifer"))
        XCTAssertFalse(NameVariants.areNameVariants("Zara", "Quinn"))
    }

    func testSubstringMatch() {
        XCTAssertTrue(NameVariants.areNameVariants("Marques Brownlee", "Marques"))
    }

    func testCaseInsensitive() {
        let expanded = NameVariants.expandName("MIKE")
        XCTAssertTrue(expanded.contains("michael"))
    }
}

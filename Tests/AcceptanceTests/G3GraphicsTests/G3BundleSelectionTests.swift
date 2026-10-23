import XCTest

final class G3BundleSelectionTests: XCTestCase {
    func testDefaultsToComposedImage() throws {
        XCTAssertTrue(try G3BundleSelection.requiresComposed(nil))
    }

    func testAcceptsExplicitComposedAndStockValues() throws {
        XCTAssertTrue(try G3BundleSelection.requiresComposed("1"))
        XCTAssertFalse(try G3BundleSelection.requiresComposed("0"))
    }

    func testRejectsInvalidValues() {
        XCTAssertThrowsError(try G3BundleSelection.requiresComposed(""))
        XCTAssertThrowsError(try G3BundleSelection.requiresComposed("true"))
        XCTAssertThrowsError(try G3BundleSelection.requiresComposed("yes"))
    }
}

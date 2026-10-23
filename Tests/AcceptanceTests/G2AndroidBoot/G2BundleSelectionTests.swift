import XCTest

final class G2BundleSelectionTests: XCTestCase {
    func testDefaultUsesStockBaselineWhenNoBundleIsSelected() throws {
        XCTAssertFalse(
            try G2BundleSelection.requiresComposed(
                configuredValue: nil,
                hasExplicitBundle: false
            )
        )
    }

    func testExplicitBundleRequiresCompositionByDefault() throws {
        XCTAssertTrue(
            try G2BundleSelection.requiresComposed(
                configuredValue: nil,
                hasExplicitBundle: true
            )
        )
    }

    func testComposedRequirementNeedsAnExplicitBundlePath() {
        XCTAssertThrowsError(
            try G2BundleSelection.requiresComposed(
                configuredValue: "1",
                hasExplicitBundle: false
            )
        )
    }

    func testStockOverrideDisablesComposedRequirement() throws {
        XCTAssertFalse(
            try G2BundleSelection.requiresComposed(
                configuredValue: "0",
                hasExplicitBundle: true
            )
        )
    }

    func testUnknownRequirementFailsClosed() {
        XCTAssertThrowsError(
            try G2BundleSelection.requiresComposed(
                configuredValue: "yes",
                hasExplicitBundle: true
            )
        )
    }
}

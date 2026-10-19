import CoreGraphics
import GraphicsCore
import Testing

@testable import RuntimeCore

@Test(arguments: [
    (CGSize(width: 480, height: 850), 2.0, 960, 1700, 320),
    (CGSize(width: 480, height: 850), 1.0, 480, 850, 160),
])
func displayGeometryResolverMapsRetinaAndNonRetinaSizes(
    pointSize: CGSize,
    backingScale: Double,
    pixelWidth: Int,
    pixelHeight: Int,
    densityDpi: Int
) throws {
    let mode = try DisplayGeometryResolver.resolve(
        DisplayGeometry(pointSize: pointSize, backingScale: backingScale)
    )

    #expect(mode.pixelSize == PixelSize(width: pixelWidth, height: pixelHeight))
    #expect(mode.densityDpi == densityDpi)
    #expect(mode.renderScale == backingScale)
    #expect(mode.zoom == 1)
    #expect(mode.refreshHz == 60)
    #expect(graphicsMode(for: mode).isSupported)
}

@Test
func displayGeometryResolverCapsPixelsAndRoundsThemDownToEvenDimensions() throws {
    let mode = try DisplayGeometryResolver.resolve(
        DisplayGeometry(pointSize: CGSize(width: 3000, height: 3000), backingScale: 2)
    )

    #expect(mode.pixelSize.width <= DisplayGeometryResolver.maximumPixelDimension)
    #expect(mode.pixelSize.height <= DisplayGeometryResolver.maximumPixelDimension)
    #expect(mode.pixelSize.width.isMultiple(of: 2))
    #expect(mode.pixelSize.height.isMultiple(of: 2))
    #expect(mode.renderScale < 4095.0 / 3000.0)
    #expect(graphicsMode(for: mode).isSupported)
}

@Test(arguments: [
    DisplayGeometry(pointSize: CGSize(width: 320, height: 400), backingScale: 1),
    DisplayGeometry(pointSize: CGSize(width: 850, height: 480), backingScale: 1),
    DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 2),
])
func displayGeometryResolverProducesModesTheEdidCanExpress(_ geometry: DisplayGeometry) throws {
    let mode = try DisplayGeometryResolver.resolve(geometry)

    #expect(graphicsMode(for: mode).isSupported)
}

@Test(arguments: [
    (1.0, 0.1, 0.75, 120),
    (2.0, 3.0, 2.0, 640),
])
func displayGeometryResolverClampsZoomToPreferenceAndDensityLimits(
    backingScale: Double,
    requestedZoom: Double,
    effectiveZoom: Double,
    densityDpi: Int
) throws {
    let pointSize = CGSize(width: 640, height: 800)
    let mode = try DisplayGeometryResolver.resolve(
        DisplayGeometry(pointSize: pointSize, backingScale: backingScale, zoom: requestedZoom)
    )

    #expect(mode.zoom == effectiveZoom)
    #expect(mode.densityDpi == densityDpi)
}

@Test
func displayGeometryResolverAdjustsZoomWhenThePixelCapWouldLowerDensity() throws {
    let geometry = DisplayGeometry(pointSize: CGSize(width: 5000, height: 5000), backingScale: 1, zoom: 0.75)
    let mode = try DisplayGeometryResolver.resolve(geometry)
    let maximumRenderScale = 4095.0 / 5000.0
    let expectedZoom = 120.0 / (160.0 * mode.renderScale)
    let minimumPointSize = try DisplayGeometryResolver.minimumPointSize(for: geometry)

    #expect(mode.pixelSize.width < DisplayGeometryResolver.maximumPixelDimension)
    #expect(mode.pixelSize.height < DisplayGeometryResolver.maximumPixelDimension)
    #expect(mode.renderScale < maximumRenderScale)
    #expect(abs(mode.zoom - expectedZoom) < 0.001)
    #expect(mode.densityDpi == 120)
    #expect(graphicsMode(for: mode).isSupported)
    #expect(mode.pixelSize.width.isMultiple(of: 2))
    #expect(mode.pixelSize.height.isMultiple(of: 2))
    #expect(minimumPointSize.width == CGFloat(320.0 * mode.zoom))
    #expect(minimumPointSize.height == CGFloat(400.0 * mode.zoom))
}

@Test
func displayGeometryResolverPreservesTheMinimumAndroidContentSize() throws {
    let minimumGeometry = DisplayGeometry(pointSize: CGSize(width: 320, height: 400), backingScale: 1)
    let mode = try DisplayGeometryResolver.resolve(minimumGeometry)

    #expect(mode.pixelSize == PixelSize(width: 320, height: 400))
    #expect(try DisplayGeometryResolver.minimumPointSize(for: minimumGeometry) == CGSize(width: 320, height: 400))
}

@Test
func displayGeometryResolverAcceptsTheMinimumSizeAtTheLowestZoom() throws {
    let geometry = DisplayGeometry(pointSize: CGSize(width: 240, height: 300), backingScale: 1, zoom: 0.75)
    let mode = try DisplayGeometryResolver.resolve(geometry)

    #expect(mode.zoom == 0.75)
    #expect(mode.densityDpi == 120)
    #expect(mode.pixelSize == PixelSize(width: 240, height: 300))
    #expect(graphicsMode(for: mode).isSupported)
}

@Test
func displayGeometryResolverReportsTheMinimumForAnUndersizedCandidate() throws {
    let geometry = DisplayGeometry(pointSize: CGSize(width: 100, height: 100), backingScale: 2)

    #expect(try DisplayGeometryResolver.minimumPointSize(for: geometry) == CGSize(width: 320, height: 400))
    #expect(throws: DisplayGeometryResolverFailure.belowMinimumSize(width: 320, height: 400)) {
        try DisplayGeometryResolver.resolve(geometry)
    }
}

@Test
func displayGeometryResolverRejectsContentBelowTheZoomAdjustedMinimum() {
    let geometry = DisplayGeometry(pointSize: CGSize(width: 479, height: 600), backingScale: 1, zoom: 1.5)

    #expect(throws: DisplayGeometryResolverFailure.belowMinimumSize(width: 480, height: 600)) {
        try DisplayGeometryResolver.resolve(geometry)
    }
}

@Test
func displayGeometryResolverRejectsLargeWindowsWithTooLittleDensity() {
    let geometry = DisplayGeometry(pointSize: CGSize(width: 12_000, height: 12_000), backingScale: 1)
    let requiredZoom = 120.0 / (160.0 * (4095.0 / 12_000.0))

    #expect(
        throws: DisplayGeometryResolverFailure.densityRangeRequiresZoomOutsidePreference(
            requiredZoom: requiredZoom
        )
    ) {
        try DisplayGeometryResolver.resolve(geometry)
    }
}

@Test
func displayGeometryResolverRejectsHighBackingScalesWithTooMuchDensity() {
    let geometry = DisplayGeometry(pointSize: CGSize(width: 700, height: 700), backingScale: 8, zoom: 2)
    let requiredZoom = 640.0 / (160.0 * (4095.0 / 700.0))

    #expect(
        throws: DisplayGeometryResolverFailure.densityRangeRequiresZoomOutsidePreference(
            requiredZoom: requiredZoom
        )
    ) {
        try DisplayGeometryResolver.resolve(geometry)
    }
}

@Test(arguments: [
    DisplayGeometry(pointSize: CGSize(width: 0, height: 400), backingScale: 1),
    DisplayGeometry(pointSize: CGSize(width: 320, height: 400), backingScale: .infinity),
    DisplayGeometry(pointSize: CGSize(width: 320, height: 400), backingScale: 1, zoom: .nan),
])
func displayGeometryResolverRejectsInvalidInputs(_ geometry: DisplayGeometry) {
    #expect(throws: DisplayGeometryResolverFailure.invalidGeometry) {
        try DisplayGeometryResolver.resolve(geometry)
    }
}

private func graphicsMode(for mode: ResolvedDisplayMode) -> DisplayMode {
    DisplayMode(
        widthPixels: mode.pixelSize.width,
        heightPixels: mode.pixelSize.height,
        refreshHz: mode.refreshHz,
        dotsPerInch: mode.densityDpi
    )
}

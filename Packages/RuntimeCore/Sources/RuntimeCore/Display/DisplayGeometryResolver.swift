import CoreGraphics
import GraphicsCore

/// The logical size of an Android display window in macOS points.
public struct DisplayGeometry: Equatable, Sendable {
    /// The width and height of the window's content area in points.
    public var pointSize: CGSize

    /// The window's backing scale factor.
    public var backingScale: Double

    /// The requested UI zoom for the package.
    public var zoom: Double

    /// Creates display geometry from a point size, backing scale, and requested zoom.
    public init(pointSize: CGSize, backingScale: Double, zoom: Double = 1) {
        self.pointSize = pointSize
        self.backingScale = backingScale
        self.zoom = zoom
    }
}

/// An integer pixel size suitable for a virtio-gpu scanout mode.
public struct PixelSize: Equatable, Sendable {
    /// The horizontal pixel count.
    public var width: Int

    /// The vertical pixel count.
    public var height: Int

    /// Creates a pixel size.
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// The display mode derived from macOS window geometry.
public struct ResolvedDisplayMode: Equatable, Sendable {
    /// The even-sized pixel dimensions to use for the scanout.
    public var pixelSize: PixelSize

    /// The density to force for the Android display.
    public var densityDpi: Int

    /// The scale used to render macOS points as Android display pixels.
    public var renderScale: Double

    /// The zoom after applying the preference and density limits.
    public var zoom: Double

    /// The refresh rate for the Android display.
    public var refreshHz: Int

    /// Creates a resolved display mode.
    public init(pixelSize: PixelSize, densityDpi: Int, renderScale: Double, zoom: Double, refreshHz: Int) {
        self.pixelSize = pixelSize
        self.densityDpi = densityDpi
        self.renderScale = renderScale
        self.zoom = zoom
        self.refreshHz = refreshHz
    }
}

/// A failure to resolve invalid or undersized display geometry.
public enum DisplayGeometryResolverFailure: Error, Equatable, Sendable {
    /// The point size, backing scale, or requested zoom is not finite and positive.
    case invalidGeometry

    /// The window is smaller than the minimum size required by its effective zoom.
    case belowMinimumSize(width: Double, height: Double)

    /// The density limits require a zoom outside the persisted preference range.
    case densityRangeRequiresZoomOutsidePreference(requiredZoom: Double)

    /// No mode at the preferred refresh rate fits the EDID timing and range limits.
    case noExpressibleMode(width: Double, height: Double, refreshHz: Int)
}

/// Resolves macOS window geometry into an Android scanout mode.
public enum DisplayGeometryResolver {
    /// The minimum content size in Android density-independent pixels.
    public static let minimumContentSizeDp = PixelSize(width: 320, height: 400)

    /// The smallest and largest supported Android densities.
    public static let densityRange = 120...640

    /// The supported package zoom preference range.
    public static let zoomRange = 0.75...2.0

    /// The largest active pixel dimension expressible by the EDID detailed timing.
    public static let maximumPixelDimension = 4095

    private static let preferredRefreshRate = 60
    private static let baseDensityDpi = 160.0

    /// Resolves point dimensions, backing scale, and zoom into a display mode.
    ///
    /// The requested zoom is first clamped to the package preference range. It is then
    /// adjusted only as needed to keep the resulting density in `densityRange`.
    /// The input point size must meet the minimum content size at that effective zoom.
    public static func resolve(_ geometry: DisplayGeometry) throws(DisplayGeometryResolverFailure)
        -> ResolvedDisplayMode
    {
        try resolve(geometry, enforcingMinimumSize: true)
    }

    private static func resolve(
        _ geometry: DisplayGeometry,
        enforcingMinimumSize: Bool
    ) throws(DisplayGeometryResolverFailure) -> ResolvedDisplayMode {
        let pointWidth = Double(geometry.pointSize.width)
        let pointHeight = Double(geometry.pointSize.height)
        guard
            pointWidth.isFinite, pointWidth > 0,
            pointHeight.isFinite, pointHeight > 0,
            geometry.backingScale.isFinite, geometry.backingScale > 0,
            geometry.zoom.isFinite, geometry.zoom > 0
        else {
            throw .invalidGeometry
        }

        let maximumRenderScale = min(
            geometry.backingScale,
            Double(maximumPixelDimension) / pointWidth,
            Double(maximumPixelDimension) / pointHeight
        )

        if let mode = try resolvedMode(
            pointWidth: pointWidth,
            pointHeight: pointHeight,
            requestedZoom: geometry.zoom,
            renderScale: maximumRenderScale,
            enforcingMinimumSize: enforcingMinimumSize
        ) {
            return mode
        }

        // The 12-bit EDID dimensions are not the only timing limit. At 60 Hz, a
        // mode near 4095 x 4095 exceeds the detailed-timing pixel clock, so lower
        // the render scale until the mode is expressible, then maximize that scale.
        var highestUnsupportedScale = maximumRenderScale
        var scale = maximumRenderScale
        var best: ResolvedDisplayMode?
        for _ in 0..<64 {
            scale *= 0.95
            guard scale > 0 else {
                break
            }
            do throws(DisplayGeometryResolverFailure) {
                if let candidate = try resolvedMode(
                    pointWidth: pointWidth,
                    pointHeight: pointHeight,
                    requestedZoom: geometry.zoom,
                    renderScale: scale,
                    enforcingMinimumSize: enforcingMinimumSize
                ) {
                    best = candidate
                    break
                }
            } catch .densityRangeRequiresZoomOutsidePreference(let requiredZoom) {
                if requiredZoom > zoomRange.upperBound {
                    break
                }
            } catch .belowMinimumSize {
                break
            } catch {
                throw error
            }
            highestUnsupportedScale = scale
        }
        guard var best else {
            throw .noExpressibleMode(
                width: pointWidth,
                height: pointHeight,
                refreshHz: preferredRefreshRate
            )
        }

        var lowestSupportedScale = best.renderScale
        for _ in 0..<40 {
            let midpoint = (lowestSupportedScale + highestUnsupportedScale) / 2
            guard midpoint > lowestSupportedScale, midpoint < highestUnsupportedScale else {
                break
            }
            guard
                let candidate = try? resolvedMode(
                    pointWidth: pointWidth,
                    pointHeight: pointHeight,
                    requestedZoom: geometry.zoom,
                    renderScale: midpoint,
                    enforcingMinimumSize: enforcingMinimumSize
                )
            else {
                highestUnsupportedScale = midpoint
                continue
            }
            best = candidate
            lowestSupportedScale = midpoint
        }
        return best
    }

    /// Returns the minimum point dimensions that preserve 320 × 400 dp for this geometry's zoom.
    ///
    /// EDID timing limits may lower the render scale, which can in turn change the
    /// density-limited effective zoom.
    public static func minimumPointSize(
        for geometry: DisplayGeometry
    ) throws(DisplayGeometryResolverFailure) -> CGSize {
        let mode = try resolve(geometry, enforcingMinimumSize: false)
        let minimumSize = minimumPointSize(forZoom: mode.zoom)
        return CGSize(width: minimumSize.width, height: minimumSize.height)
    }

    private static func resolvedZoom(
        requestedZoom: Double,
        renderScale: Double
    ) throws(DisplayGeometryResolverFailure) -> Double {
        let preferenceZoom = min(zoomRange.upperBound, max(zoomRange.lowerBound, requestedZoom))
        let densityPerZoom = baseDensityDpi * renderScale
        let densityAtPreferenceZoom = densityPerZoom * preferenceZoom
        if !densityAtPreferenceZoom.isFinite || densityAtPreferenceZoom >= Double(densityRange.upperBound) + 0.5 {
            return try zoomRequired(forDensity: densityRange.upperBound, densityPerZoom: densityPerZoom)
        }

        if densityAtPreferenceZoom < Double(densityRange.lowerBound) - 0.5 {
            return try zoomRequired(forDensity: densityRange.lowerBound, densityPerZoom: densityPerZoom)
        }

        return preferenceZoom
    }

    private static func resolvedMode(
        pointWidth: Double,
        pointHeight: Double,
        requestedZoom: Double,
        renderScale: Double,
        enforcingMinimumSize: Bool
    ) throws(DisplayGeometryResolverFailure) -> ResolvedDisplayMode? {
        let effectiveZoom = try resolvedZoom(requestedZoom: requestedZoom, renderScale: renderScale)
        let minimumSize = minimumPointSize(forZoom: effectiveZoom)
        guard
            !enforcingMinimumSize
                || (pointWidth >= minimumSize.width && pointHeight >= minimumSize.height)
        else {
            throw .belowMinimumSize(width: minimumSize.width, height: minimumSize.height)
        }

        let pixelSize = PixelSize(
            width: evenPixelDimension(pointWidth * renderScale),
            height: evenPixelDimension(pointHeight * renderScale)
        )
        let density = min(
            densityRange.upperBound,
            max(densityRange.lowerBound, Int((baseDensityDpi * renderScale * effectiveZoom).rounded()))
        )
        let graphicsMode = DisplayMode(
            widthPixels: pixelSize.width,
            heightPixels: pixelSize.height,
            refreshHz: preferredRefreshRate,
            dotsPerInch: density
        )
        guard graphicsMode.isSupported else {
            return nil
        }

        return ResolvedDisplayMode(
            pixelSize: pixelSize,
            densityDpi: density,
            renderScale: renderScale,
            zoom: effectiveZoom,
            refreshHz: preferredRefreshRate
        )
    }

    private static func zoomRequired(
        forDensity density: Int,
        densityPerZoom: Double
    ) throws(DisplayGeometryResolverFailure) -> Double {
        let requiredZoom = Double(density) / densityPerZoom
        guard zoomRange.contains(requiredZoom) else {
            throw .densityRangeRequiresZoomOutsidePreference(requiredZoom: requiredZoom)
        }
        return requiredZoom
    }

    private static func minimumPointSize(forZoom zoom: Double) -> (width: Double, height: Double) {
        (
            width: Double(minimumContentSizeDp.width) * zoom,
            height: Double(minimumContentSizeDp.height) * zoom
        )
    }

    private static func evenPixelDimension(_ unroundedPixels: Double) -> Int {
        let roundedPixels = Int(unroundedPixels.rounded())
        return max(2, roundedPixels - roundedPixels % 2)
    }
}

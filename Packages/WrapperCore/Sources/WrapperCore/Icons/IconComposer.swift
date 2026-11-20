import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO

/// Composes the 1024 × 1024 sRGB opaque master icon (wrapper.md §8.2).
///
/// Pure Core Graphics and ImageIO: no AppKit, so the composition runs inside
/// apkrund without a window server connection.
public enum IconComposer {
    /// The master canvas edge (wrapper.md §8.2).
    public static let masterSizePx = 1024
    /// The guest renders adaptive layers at this size so the inner 72 dp are
    /// exactly 1024 px (guest-protocol.md §11.1).
    public static let adaptiveRenderSizePx = 1536
    /// A non-square legacy icon fits inside this centered box on white.
    static let fittedBoxSizePx = 820

    /// Composes an adaptive icon: background then foreground on the 1536 px
    /// canvas, white beneath any alpha, cropped to the centered 1024 px square
    /// (wrapper.md §8.2 `adaptive`).
    public static func composeAdaptive(
        background: CGImage,
        foreground: CGImage
    ) throws(WrapperFailure) -> CGImage {
        let canvas = try opaqueContext(size: adaptiveRenderSizePx)
        canvas.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: CGFloat(adaptiveRenderSizePx), height: CGFloat(adaptiveRenderSizePx)))
        let full = CGRect(x: 0, y: 0, width: CGFloat(adaptiveRenderSizePx), height: CGFloat(adaptiveRenderSizePx))
        canvas.draw(background, in: full)
        canvas.draw(foreground, in: full)
        guard let composed = canvas.makeImage() else {
            throw .iconConversionFailed("cannot rasterize the adaptive icon")
        }
        // Crop the centered 1024 px square (the inner 72 dp).
        let inset = CGFloat(adaptiveRenderSizePx - masterSizePx) / 2
        let crop = CGRect(x: inset, y: inset, width: CGFloat(masterSizePx), height: CGFloat(masterSizePx))
        guard let master = composed.cropping(to: crop) else {
            throw .iconConversionFailed("cannot crop the adaptive icon")
        }
        return master
    }

    /// Composes a legacy icon or host preview bitmap: the transparent border
    /// (alpha < 8) is trimmed; a square, corner-opaque result scales to the
    /// full 1024 px, anything else fits inside the centered 820 px box on
    /// white (wrapper.md §8.2 `legacy`).
    public static func composeLegacy(_ image: CGImage) throws(WrapperFailure) -> CGImage {
        guard let trimmed = try trimTransparentBorder(image) else {
            // Fully transparent: draw an empty opaque master.
            let canvas = try opaqueContext(size: masterSizePx)
            canvas.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: CGFloat(masterSizePx), height: CGFloat(masterSizePx)))
            guard let blank = canvas.makeImage() else {
                throw .iconConversionFailed("cannot rasterize the icon")
            }
            return blank
        }
        let canvas = try opaqueContext(size: masterSizePx)
        canvas.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: CGFloat(masterSizePx), height: CGFloat(masterSizePx)))
        canvas.interpolationQuality = .high
        let aspect = Double(trimmed.width) / Double(trimmed.height)
        if aspect >= 0.97, aspect <= 1.03, cornersAreOpaque(trimmed) {
            canvas.draw(trimmed, in: CGRect(x: 0, y: 0, width: CGFloat(masterSizePx), height: CGFloat(masterSizePx)))
        } else {
            let box = fit(
                width: trimmed.width, height: trimmed.height,
                into: CGSize(width: fittedBoxSizePx, height: fittedBoxSizePx))
            let offset = CGFloat(masterSizePx - fittedBoxSizePx) / 2
            canvas.draw(trimmed, in: box.offsetBy(dx: offset, dy: offset))
        }
        guard let master = canvas.makeImage() else {
            throw .iconConversionFailed("cannot rasterize the icon")
        }
        return master
    }

    /// Composes the placeholder: the display name's first grapheme, white,
    /// centered on a flat color derived from SHA-256(packageID)
    /// (wrapper.md §8.2 `placeholder`).
    public static func composePlaceholder(packageID: String, displayName: String)
        throws(WrapperFailure) -> CGImage
    {
        let digest = SHA256.hash(data: Data(packageID.utf8))
        let bytes = Array(digest)
        let hue = Double(bytes[0]) / 255.0
        let saturation = 0.45 + Double(bytes[1]) / 255.0 * 0.25
        let brightness = 0.55 + Double(bytes[2]) / 255.0 * 0.2
        let canvas = try opaqueContext(size: masterSizePx)
        canvas.setFillColor(
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: CGFloat(masterSizePx), height: CGFloat(masterSizePx)))
        canvas.setFillColor(hsb(hue: hue, saturation: saturation, brightness: brightness))
        canvas.fill(CGRect(x: 0, y: 0, width: CGFloat(masterSizePx), height: CGFloat(masterSizePx)))

        let grapheme = displayName.first.map(String.init) ?? "?"
        let font = CTFontCreateWithName(".AppleSystemUIFontHeavy" as CFString, 560, nil)
        let attributes =
            [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            ] as [CFString: Any]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: grapheme,
                attributes: attributes as [NSAttributedString.Key: Any]))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        canvas.textPosition = CGPoint(
            x: (CGFloat(masterSizePx) - bounds.width) / 2 - bounds.minX,
            y: (CGFloat(masterSizePx) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, canvas)
        guard let master = canvas.makeImage() else {
            throw .iconConversionFailed("cannot rasterize the placeholder")
        }
        return master
    }

    /// Reads a user-provided icon (wrapper.md §8.2 `custom`): PNG, JPEG, or
    /// HEIC at least 512 px square is composed through `composeLegacy`;
    /// an `.icns` is returned unchanged.
    public static func customIconData(at url: URL) throws(WrapperFailure) -> Data {
        guard let data = try? Data(contentsOf: url) else {
            throw .customIconInvalid(.unreadable)
        }
        if data.prefix(4) == Data("icns".utf8) {
            return data
        }
        // §8.2 `custom`: PNG/JPEG/HEIC are composed into an `.icns`, the
        // same finished format the bundle's AppIcon.icns expects.
        let master = try customIconMaster(at: url)
        return try IconsetWriter.icnsData(from: master)
    }

    /// The 1024 px PNG master of a custom icon, stored as the
    /// `Wrappers/icons/<bundleId>.png` source a refresh can reuse
    /// (wrapper.md §4.2).
    public static func customIconPNG(at url: URL) throws(WrapperFailure) -> Data {
        let master = try customIconMaster(at: url)
        return try pngData(master)
    }

    /// Validates a custom icon file and returns its composed 1024 px master.
    static func customIconMaster(at url: URL) throws(WrapperFailure) -> CGImage {
        guard let data = try? Data(contentsOf: url) else {
            throw .customIconInvalid(.unreadable)
        }
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw .customIconInvalid(.unreadable)
        }
        guard image.width == image.height else {
            throw .customIconInvalid(.notSquare)
        }
        guard image.width >= 512 else {
            throw .customIconInvalid(.tooSmall)
        }
        return try composeLegacy(image)
    }

    /// Encodes a master as PNG.
    public static func pngData(_ image: CGImage) throws(WrapperFailure) -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, "public.png" as CFString, 1, nil)
        else {
            throw .iconConversionFailed("cannot create an image destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw .iconConversionFailed("cannot encode PNG")
        }
        return data as Data
    }

    // MARK: - §8.2 helpers

    /// An opaque sRGB bitmap context at `size`².
    static func opaqueContext(size: Int) throws(WrapperFailure) -> CGContext {
        guard
            let context = CGContext(
                data: nil, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else {
            throw .iconConversionFailed("cannot create CGContext")
        }
        return context
    }

    /// The smallest rectangle holding pixels with alpha ≥ 8, or nil when the
    /// image is fully transparent.
    static func trimTransparentBorder(_ image: CGImage) throws(WrapperFailure) -> CGImage? {
        guard let pixels = rgbaPixels(image) else {
            throw .iconConversionFailed("cannot decode the icon pixels")
        }
        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where pixels[y * image.width + x] >= 8 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return image.cropping(
            to: CGRect(
                x: minX, y: minY,
                width: maxX - minX + 1, height: maxY - minY + 1))
    }

    /// Whether all four corners at 2 % insets have alpha ≥ 250. An image
    /// too small for distinct corner samples counts as not opaque.
    static func cornersAreOpaque(_ image: CGImage) -> Bool {
        guard image.width >= 4, image.height >= 4,
            let pixels = rgbaPixels(image)
        else { return false }
        let insetX = max(1, image.width / 50)
        let insetY = max(1, image.height / 50)
        let corners = [
            (insetX, insetY),
            (image.width - 1 - insetX, insetY),
            (insetX, image.height - 1 - insetY),
            (image.width - 1 - insetX, image.height - 1 - insetY),
        ]
        return corners.allSatisfy { pixels[$1 * image.width + $0] >= 250 }
    }

    /// The alpha channel of the image as bytes, one per pixel.
    private static func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ), let data = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let buffer = data.bindMemory(to: UInt8.self, capacity: image.width * image.height)
        return Array(UnsafeBufferPointer(start: buffer, count: image.width * image.height))
    }

    /// Scales `width`×`height` to fit inside `box`, preserving aspect.
    static func fit(width: Int, height: Int, into box: CGSize) -> CGRect {
        let scale = min(box.width / CGFloat(width), box.height / CGFloat(height))
        let fitted = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        return CGRect(
            x: (box.width - fitted.width) / 2, y: (box.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height)
    }

    /// An HSB color as sRGB (no AppKit NSColor).
    private static func hsb(hue: Double, saturation: Double, brightness: Double) -> CGColor {
        let c = brightness * saturation
        let x = c * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (Double, Double, Double)
        switch hue * 6 {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return CGColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: 1)
    }
}

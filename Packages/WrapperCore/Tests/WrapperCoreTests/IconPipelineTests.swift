import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing

@testable import WrapperCore

// MARK: - T0: icon pipeline §8.2–§8.5

/// A solid RGBA CGImage for tests.
private func image(size: Int, r: Double, g: Double, b: Double, a: Double = 1)
    throws -> CGImage
{
    guard
        let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { throw WrapperFailure.iconConversionFailed("ctx") }
    context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: a))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = context.makeImage() else {
        throw WrapperFailure.iconConversionFailed("img")
    }
    return image
}

/// Decodes PNG bytes back to a CGImage.
private func decode(_ png: Data) -> CGImage? {
    CGImageSourceCreateWithData(png as CFData, nil)
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
}

/// The center pixel's alpha of a CGImage (0–255).
private func centerAlpha(_ image: CGImage) -> UInt8 {
    guard
        let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ), let data = context.data
    else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = data.bindMemory(to: UInt8.self, capacity: image.width * image.height)
    return pixels[(image.height / 2) * image.width + image.width / 2]
}

@Test func adaptiveIconCropsCenteredMaster() throws {
    // §8.2: bg+fg on the 1536 canvas, cropped to the centered 1024.
    let master = try IconComposer.composeAdaptive(
        background: image(size: 1536, r: 1, g: 0, b: 0),
        foreground: image(size: 1536, r: 0, g: 1, b: 0, a: 0.25))
    #expect(master.width == 1024 && master.height == 1024)
    let png = try IconComposer.pngData(master)
    #expect(png.count > 100)
    #expect(decode(png)?.width == 1024)
}

@Test func legacySquareOpaqueIconFillsMaster() throws {
    // Opaque square input scales to the full 1024 px.
    let master = try IconComposer.composeLegacy(try image(size: 300, r: 0.2, g: 0.4, b: 0.9))
    #expect(master.width == 1024)
    #expect(centerAlpha(master) == 255)
}

@Test func legacyNonSquareIconFits820Box() throws {
    // A 2:1 landscape icon sits inside the centered 820 box on white.
    let master = try IconComposer.composeLegacy(
        try image(size: 400, r: 1, g: 0, b: 0).cropping(
            to: CGRect(x: 0, y: 100, width: 400, height: 200))!)
    #expect(master.width == 1024)
}

@Test func fullyTransparentIconYieldsWhiteMaster() throws {
    let master = try IconComposer.composeLegacy(try image(size: 64, r: 0, g: 0, b: 0, a: 0))
    #expect(master.width == 1024)
    #expect(centerAlpha(master) == 255)
}

@Test func placeholderIsDeterministicPerPackage() throws {
    let a = try IconComposer.composePlaceholder(packageID: "com.example.a", displayName: "A")
    let b = try IconComposer.composePlaceholder(packageID: "com.example.a", displayName: "A")
    let c = try IconComposer.composePlaceholder(packageID: "com.example.b", displayName: "B")
    #expect(try IconComposer.pngData(a) == IconComposer.pngData(b))
    #expect(try IconComposer.pngData(a) != IconComposer.pngData(c))
    #expect(a.width == 1024)
}

@Test func customIconRejectsNonSquareOrSmall() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("icon-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    let small = try image(size: 256, r: 0, g: 0, b: 1)
    try IconComposer.pngData(small).write(to: url)
    #expect(throws: WrapperFailure.self) {
        _ = try IconComposer.customIconData(at: url)
    }
    // .icns passes through untouched.
    let icns = try ICNSWriter.icnsData(pngs: [
        IconsetWriter.SlotPNG(
            slot: IconsetLayout.slots[0], png: try IconComposer.pngData(small))
    ])
    try icns.write(to: url)
    #expect(try IconComposer.customIconData(at: url) == icns)
}

@Test func icnsWriterIsDeterministicAndWellFormed() throws {
    let master = try IconComposer.composeLegacy(try image(size: 512, r: 0.5, g: 0.1, b: 0.1))
    let pngs = try IconsetWriter.renderPNGs(from: master)
    #expect(pngs.count == IconsetLayout.slots.count)
    // Every slot renders at its size.
    for slot in zip(pngs, IconsetLayout.slots) {
        #expect(decode(slot.0.png)?.width == slot.1.pixels)
    }
    // §8.3: iconutil output and §8.4 fallback produce the same container.
    let icns = try IconsetWriter.icnsData(from: master, runIconUtil: { _, _ in false })
    let again = try ICNSWriter.icnsData(pngs: pngs)
    #expect(icns == again)
    #expect(icns.prefix(4) == Data("icns".utf8))
    // The container length field covers every entry.
    let declared = icns[4..<8].reduce(0) { ($0 << 8) | UInt32($1) }
    #expect(declared == icns.count)
    // Every icns slot type is present in order.
    for slot in IconsetLayout.slots {
        #expect(icns.contains(Data(slot.icnsType.utf8)))
    }
}

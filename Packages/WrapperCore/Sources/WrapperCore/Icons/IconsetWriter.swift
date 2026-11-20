import CoreGraphics
import Foundation
import ImageIO

/// The iconset sizes and `icns` element types of a wrapper icon
/// (wrapper.md §8.3–§8.4). `ic04`–`ic14` cover the 16–1024 px masters.
public enum IconsetLayout {
    /// One rendered slot: its iconset file name, pixel edge, and icns type.
    public struct Slot: Sendable, Equatable {
        /// `icon_…` file name inside the `.iconset` directory.
        public var fileName: String
        /// The rendered pixel edge.
        public var pixels: Int
        /// The `icns` element type this slot becomes.
        public var icnsType: String
    }

    /// The seven sizes of wrapper.md §8.3, smallest named slot per size.
    public static let slots: [Slot] = [
        Slot(fileName: "icon_16x16.png", pixels: 16, icnsType: "ic04"),
        Slot(fileName: "icon_16x16@2x.png", pixels: 32, icnsType: "ic05"),
        Slot(fileName: "icon_32x32@2x.png", pixels: 64, icnsType: "ic11"),
        Slot(fileName: "icon_128x128.png", pixels: 128, icnsType: "ic07"),
        Slot(fileName: "icon_128x128@2x.png", pixels: 256, icnsType: "ic13"),
        Slot(fileName: "icon_256x256@2x.png", pixels: 512, icnsType: "ic14"),
        Slot(fileName: "icon_512x512@2x.png", pixels: 1024, icnsType: "ic10"),
    ]
}

/// Writes the `AppIcon.iconset` directory and converts it with
/// `/usr/bin/iconutil` (wrapper.md §8.3).
public enum IconsetWriter {
    /// Renders every slot PNG of the iconset (§8.3 step 1).
    public static func renderPNGs(from master: CGImage) throws(WrapperFailure) -> [SlotPNG] {
        var pngs: [SlotPNG] = []
        for slot in IconsetLayout.slots {
            let scaled = try downscale(master, to: slot.pixels)
            pngs.append(SlotPNG(slot: slot, png: try IconComposer.pngData(scaled)))
        }
        return pngs
    }

    /// Writes the iconset, converts it to `.icns` with `iconutil`, and removes
    /// the iconset (§8.3 steps 1–3). When `iconutil` fails or produces
    /// non-deterministic output, `ICNSWriter` writes the container directly
    /// (§8.4).
    public static func icnsData(
        from master: CGImage,
        fileManager: FileManager = .default,
        runIconUtil: @Sendable (URL, URL) -> Bool = defaultIconUtil
    ) throws(WrapperFailure) -> Data {
        let pngs = try renderPNGs(from: master)
        let iconset = fileManager.temporaryDirectory
            .appendingPathComponent("apkrun-icon-\(UUID().uuidString).iconset", isDirectory: true)
        do {
            do {
                try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
            } catch {
                throw WrapperFailure.iconConversionFailed(
                    "iconset write failed: \(error.localizedDescription)")
            }
            // §8.3 step 3: the iconset goes away whether iconutil succeeds.
            defer { try? fileManager.removeItem(at: iconset) }
            for entry in pngs {
                do {
                    try entry.png.write(to: iconset.appendingPathComponent(entry.slot.fileName))
                } catch {
                    throw WrapperFailure.iconConversionFailed(
                        "iconset write failed: \(error.localizedDescription)")
                }
            }
            let output = fileManager.temporaryDirectory
                .appendingPathComponent("apkrun-icon-\(UUID().uuidString).icns")
            defer { try? fileManager.removeItem(at: output) }
            if runIconUtil(iconset, output),
                let data = fileManager.contents(atPath: output.path), !data.isEmpty
            {
                return data
            }
        } catch let failure as WrapperFailure {
            throw failure
        } catch {
            throw .iconConversionFailed("iconset write failed: \(error.localizedDescription)")
        }
        // §8.4: write the container without iconutil.
        return try ICNSWriter.icnsData(pngs: pngs)
    }

    /// One rendered iconset PNG.
    public struct SlotPNG: Sendable {
        /// The slot it fills.
        public var slot: IconsetLayout.Slot
        /// The PNG bytes.
        public var png: Data
    }

    /// Downscales the master to `pixels`² with high-quality interpolation
    /// (§8.3 step 1).
    static func downscale(_ master: CGImage, to pixels: Int) throws(WrapperFailure) -> CGImage {
        let context = try IconComposer.opaqueContext(size: pixels)
        context.interpolationQuality = .high
        context.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let scaled = context.makeImage() else {
            throw .iconConversionFailed("cannot rasterize a \(pixels)px icon")
        }
        return scaled
    }

    /// `/usr/bin/iconutil -c icns -o out.icns iconset`; false on any failure.
    public static func defaultIconUtil(iconset: URL, output: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", "-o", output.path, iconset.path]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Writes the `.icns` container directly — the `ic04`–`ic14` PNG entries —
/// when `iconutil` fails or is not deterministic (wrapper.md §8.4).
public enum ICNSWriter {
    /// Builds `icns` bytes from rendered slot PNGs.
    public static func icnsData(pngs: [IconsetWriter.SlotPNG]) throws(WrapperFailure) -> Data {
        guard !pngs.isEmpty else {
            throw .iconConversionFailed("no icon slots rendered")
        }
        var data = Data("icns".utf8)
        var body = Data()
        for entry in pngs {
            body.append(Data(entry.slot.icnsType.utf8))
            var length = UInt32(8 + entry.png.count).bigEndian
            body.append(Data(bytes: &length, count: 4))
            body.append(entry.png)
        }
        var total = UInt32(8 + body.count).bigEndian
        data.append(Data(bytes: &total, count: 4))
        data.append(body)
        return data
    }
}

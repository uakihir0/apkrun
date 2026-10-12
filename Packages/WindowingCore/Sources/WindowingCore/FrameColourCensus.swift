/// A census of the pure red and pure blue pixels of one frame (graphics.md §12 #023, the tearing check).
///
/// The alternating-colour mode of HelloGL clears each frame to one of two colours, so a frame that holds both colours
/// was written partly before and partly after the other colour. The census reads the pixels of a BGRA8 buffer, the
/// layout of the pool (IR-1107), and samples every `step`-th pixel in each direction. The tearing check uses `step` 1, so
/// every row is read: a tear of a single row is found. It reads memory only. It does not change the frame, and the
/// caller holds the buffer's lock for the call.
public struct FrameColourCensus: Equatable, Sendable {
    /// The pixels that were sampled.
    public let sampled: Int
    /// The sampled pixels close to pure red.
    public let red: Int
    /// The sampled pixels close to pure blue.
    public let blue: Int

    /// Creates the census of `sampled` pixels, of which `red` are pure red and `blue` are pure blue.
    public init(sampled: Int, red: Int, blue: Int) {
        self.sampled = sampled
        self.red = red
        self.blue = blue
    }

    /// Whether the frame holds both colours, which is a tear in the alternating-colour mode.
    public var isMixed: Bool {
        red > 0 && blue > 0
    }

    /// The byte offset of the centre pixel of a `width` x `height` BGRA8 image whose rows are `bytesPerRow` bytes long.
    ///
    /// The tearing check decides from this pixel whether a frame is read in full. The first row is not used: in the
    /// alternating-colour mode the Android status and app bars sit above the GL area, so the first row is dark.
    public static func centreOffset(width: Int, height: Int, bytesPerRow: Int) -> Int {
        (height / 2) * bytesPerRow + (width / 2) * 4
    }

    /// Whether the BGRA8 pixel at `pixel` is close to pure red or to pure blue, with the thresholds of `census`.
    ///
    /// The tearing check reads a frame in full only when its centre pixel is one of the two colours, so the normal-mode
    /// gradient of HelloGL, which is not one of them, costs one pixel read per frame.
    public static func isPureRedOrBlue(_ pixel: UnsafeRawPointer) -> Bool {
        let blueByte = Int(pixel.load(as: UInt8.self))
        let greenByte = Int(pixel.load(fromByteOffset: 1, as: UInt8.self))
        let redByte = Int(pixel.load(fromByteOffset: 2, as: UInt8.self))
        return (redByte > 180 && greenByte < 80 && blueByte < 80) || (blueByte > 180 && redByte < 80 && greenByte < 80)
    }

    /// Counts the sampled pixels of the `width` x `height` BGRA8 image at `base`. Row `y` starts at `base + y * bytesPerRow`.
    ///
    /// The caller must make `base` readable for `height` rows of `bytesPerRow` bytes, and `bytesPerRow` must hold
    /// `width` pixels. Padding bytes at the end of a row are not read.
    public static func census(
        of base: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        step: Int = 1
    ) -> FrameColourCensus {
        precondition(step > 0 && width >= 0 && height >= 0 && bytesPerRow >= width * 4)
        var sampled = 0
        var red = 0
        var blue = 0
        for y in Swift.stride(from: 0, to: height, by: step) {
            let row = base.advanced(by: y * bytesPerRow)
            for x in Swift.stride(from: 0, to: width, by: step) {
                // BGRA8: byte 0 is blue, byte 1 green, byte 2 red, byte 3 alpha.
                let pixel = row.advanced(by: x * 4)
                let blueByte = Int(pixel.load(as: UInt8.self))
                let greenByte = Int(pixel.load(fromByteOffset: 1, as: UInt8.self))
                let redByte = Int(pixel.load(fromByteOffset: 2, as: UInt8.self))
                sampled += 1
                if redByte > 180 && greenByte < 80 && blueByte < 80 {
                    red += 1
                } else if blueByte > 180 && redByte < 80 && greenByte < 80 {
                    blue += 1
                }
            }
        }
        return FrameColourCensus(sampled: sampled, red: red, blue: blue)
    }
}

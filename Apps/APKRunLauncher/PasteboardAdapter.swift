import CryptoKit
import Foundation
import RuntimeAPI
import RuntimeClient

#if canImport(AppKit)
    import AppKit
#endif
#if canImport(ImageIO)
    import ImageIO
#endif

/// The Mac-side pasteboard adapter of desktop-integration.md §4.2 and §4.4.
///
/// Reads happen on ⌘V (`trigger = .paste`) and when a package window becomes
/// key (`trigger = .focus`), never in the background; images move on ⌘V only
/// (R-21). An Android clip lands as `clearContents` + the clip's types + the
/// `io.apkrun.clip-origin` marker — the marker is loop-guard signal 3, the
/// SHA-256 digest of the normalized text or PNG bytes is signal 2, and the
/// guest `origin`/`seq` is signal 1.

/// The minimal pasteboard surface the adapter needs, for tests.
protocol PasteboardReading: Sendable {
    /// The change counter; a read compares it to the last pushed count.
    var changeCount: Int { get }
    /// The declared type identifiers.
    var types: [String] { get }
    /// The UTF-8 payload of a type, or nil.
    func string(forType type: String) -> String?
    /// The binary payload of a type, or nil.
    func data(forType type: String) -> Data?
    /// Replaces all contents with the given type payloads.
    @discardableResult
    func write(_ items: [(type: String, data: Data)]) -> Int
    /// Replaces all contents as a paste-once clip (TransientType).
    @discardableResult
    func writeTransient(_ items: [(type: String, data: Data)]) -> Int
}

/// What a guest clip write reports back as `ClipboardWritten`.
struct PasteboardWrite: Sendable {
    /// The pasteboard's change counter after the write.
    var changeCount: Int
    /// The digest stored in the `io.apkrun.clip-origin` marker.
    var digest: RuntimeSHA256Digest
}

/// Reads and writes `NSPasteboard.general` (desktop-integration.md §4.2).
///
/// All calls happen on the main thread: ⌘V monitors, window notifications,
/// and guest-clip writes all land there.
final class PasteboardAdapter {
    /// The marker that identifies an Android-origin write (§4.4, signal 3).
    static let markerType = "io.apkrun.clip-origin"
    /// `public.utf8-plain-text`.
    static let plainTextType = "public.utf8-plain-text"
    /// `public.html`.
    static let htmlType = "public.html"
    /// `public.png`.
    static let pngType = "public.png"
    /// `public.tiff`.
    static let tiffType = "public.tiff"
    /// The 1 MiB text limit; longer text is truncated at a character boundary
    /// and the window shows "Only the first 1 MB was copied." (§4.4, §11.4).
    static let textByteLimit = 1_048_576
    /// The 16 MiB image limit; a bigger image is dropped, and the window shows
    /// the limit message (§4.4).
    static let imageByteLimit = 16 * 1_048_576
    /// The 8192 px per-side image limit (§4.4).
    static let imagePixelLimit = 8192

    private let pasteboard: any PasteboardReading
    /// The change count of the last clip pushed to Android.
    private(set) var lastSentChangeCount = -1
    /// The change count of the last clip the adapter itself wrote, so a
    /// marker-stripped rewrite is still recognized.
    private(set) var lastWrittenChangeCount = -1
    /// The byte count of an image the last read dropped for exceeding the
    /// limits, or nil (§4.4: text and HTML still go, the window shows the
    /// limit message).
    private(set) var droppedImageTooLarge: Int? = nil

    /// Creates an adapter over a pasteboard.
    init(pasteboard: any PasteboardReading) {
        self.pasteboard = pasteboard
    }

    /// Reads the clip to push toward Android, or nil when nothing new is there
    /// or the contents came from Android (§4.4).
    ///
    /// A read picks up plain text, then HTML, then — only on ⌘V — an image
    /// (`public.png` first, `public.tiff` converted to PNG). HTML alone still
    /// produces the plain text a plain field needs. An image over 16 MiB or
    /// 8192 px per side is dropped (text and HTML still go); the drop is
    /// reported through ``droppedImageTooLarge``.
    func readHostClip(trigger: ClipTrigger) -> ClipItem? {
        droppedImageTooLarge = nil
        let count = pasteboard.changeCount
        guard count != lastSentChangeCount, count != lastWrittenChangeCount else {
            return nil
        }
        let types = pasteboard.types
        // Signal 3: the marker is only present on Android-origin writes.
        guard !types.contains(Self.markerType) else {
            lastSentChangeCount = count
            return nil
        }
        // A paste-once clip (password managers' TransientType) crosses only on
        // an explicit paste; focusing a window must not send it (§4.4).
        if trigger == .focus, types.contains(Self.transientType) {
            lastSentChangeCount = count
            return nil
        }
        var text =
            types.contains(Self.plainTextType)
            ? pasteboard.string(forType: Self.plainTextType)
            : nil
        let html = types.contains(Self.htmlType) ? pasteboard.string(forType: Self.htmlType) : nil
        if (text ?? "").isEmpty, let html {
            // A rich-text clip still gives the plain text a plain field needs (§4.4).
            text = Self.plainText(fromHTML: html)
        }
        if (text ?? "").isEmpty {
            text = nil
        }
        // R-21: images travel on ⌘V only, so a focus read never picks one up —
        // and an image-only clipboard does not get marked sent on focus.
        var image: ClipImage? = nil
        if trigger == .paste {
            image = readImage(types: types)
        }
        if text == nil && image == nil {
            if trigger == .paste {
                lastSentChangeCount = count
            }
            return nil
        }
        var clipped = text
        var truncated = false
        if let unclipped = clipped, unclipped.utf8.count > Self.textByteLimit {
            clipped = Self.truncate(unclipped, to: Self.textByteLimit)
            truncated = true
        }
        let digest =
            (clipped.flatMap { Self.digest(text: $0) })
            ?? image.flatMap { Self.digest(imageBytes: $0.png) }
        guard let digest else {
            return nil
        }
        lastSentChangeCount = count
        lastReadChangeCount = count
        return ClipItem(
            text: clipped,
            html: html,
            image: image,
            sensitive: types.contains(Self.concealedType),
            digest: digest,
            truncated: truncated,
            trigger: trigger
        )
    }

    /// Reads the image of the pasteboard within the §4.4 limits: `public.png`
    /// as is, `public.tiff` converted to PNG, and nothing when both are absent
    /// or the result is over the limits.
    private func readImage(types: [String]) -> ClipImage? {
        var png: Data? = nil
        if types.contains(Self.pngType), let data = pasteboard.data(forType: Self.pngType),
            !data.isEmpty
        {
            png = data
        } else if types.contains(Self.tiffType),
            let tiff = pasteboard.data(forType: Self.tiffType),
            let converted = Self.pngData(fromTIFF: tiff)
        {
            png = converted
        }
        guard let png else {
            return nil
        }
        let size = Self.imageSize(ofPNG: png)
        if png.count > Self.imageByteLimit
            || (size.map { max($0.width, $0.height) > Self.imagePixelLimit } ?? false)
        {
            droppedImageTooLarge = png.count
            return nil
        }
        guard let size else {
            return nil
        }
        return ClipImage(png: png, pixelWidth: size.width, pixelHeight: size.height)
    }

    /// Unmarks a clip whose push failed, so a later paste retries it.
    func pushFailed(changeCount: Int) {
        if lastSentChangeCount == changeCount {
            lastSentChangeCount = -1
        }
    }

    /// The change count of the clip the last read returned.
    private(set) var lastReadChangeCount = -1

    /// Writes a guest clip and returns what `clipboardWritten` reports (§4.2).
    ///
    /// The write is `clearContents` + the clip's types + the origin marker.
    /// An image lands as `public.png`. Sensitive clips use the concealed type;
    /// the transient type marks a clip the window pastes once, not a store the
    /// Mac keeps.
    @discardableResult
    func writeGuestClip(
        _ item: ClipItem,
        package: String,
        seq: UInt64,
        transient: Bool = false
    ) -> PasteboardWrite? {
        guard item.text != nil || item.image != nil else {
            return nil
        }
        var items: [(type: String, data: Data)] = []
        if let text = item.text {
            items.append((Self.plainTextType, Data(text.utf8)))
        }
        if let html = item.html {
            items.append((Self.htmlType, Data(html.utf8)))
        }
        if let image = item.image {
            items.append((Self.pngType, image.png))
        }
        if item.sensitive {
            items.append((Self.concealedType, Data()))
        }
        items.append(
            (Self.markerType, Data("\(package)|\(seq)|\(item.digest.rawValue)".utf8)))
        let count: Int
        if transient {
            count = pasteboard.writeTransient(items)
        } else {
            count = pasteboard.write(items)
        }
        lastWrittenChangeCount = count
        lastSentChangeCount = count
        return PasteboardWrite(changeCount: count, digest: item.digest)
    }

    /// `org.nspasteboard.ConcealedType` — password managers' mark for secrets.
    static let concealedType = "org.nspasteboard.ConcealedType"
    /// `org.nspasteboard.TransientType` — paste-once content.
    static let transientType = "org.nspasteboard.TransientType"

    /// The §4.4 digest: SHA-256 over the NFC-normalized text's UTF-8 bytes.
    static func digest(text: String) -> RuntimeSHA256Digest? {
        let normalized = text.precomposedStringWithCanonicalMapping
        let hash = SHA256.hash(data: Data(normalized.utf8))
        return RuntimeSHA256Digest(
            rawValue: "sha256:" + hash.map { String(format: "%02x", $0) }.joined())
    }

    /// The §4.4 digest of an image clip: SHA-256 over the PNG bytes.
    static func digest(imageBytes: Data) -> RuntimeSHA256Digest? {
        guard !imageBytes.isEmpty else { return nil }
        let hash = SHA256.hash(data: imageBytes)
        return RuntimeSHA256Digest(
            rawValue: "sha256:" + hash.map { String(format: "%02x", $0) }.joined())
    }

    /// Cuts the text at the character boundary within `byteLimit` UTF-8 bytes.
    static func truncate(_ text: String, to byteLimit: Int) -> String {
        var bytes = 0
        var end = text.startIndex
        for character in text {
            let next = bytes + character.utf8.count
            guard next <= byteLimit else { break }
            bytes = next
            end = text.index(after: end)
        }
        return String(text[..<end])
    }

    /// The plain text an HTML-only clip gives a plain field (§4.4).
    static func plainText(fromHTML html: String) -> String? {
        #if canImport(AppKit)
            if let attributed = NSAttributedString(
                html: Data(html.utf8),
                options: [.characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
            ) {
                let text = attributed.string
                return text.isEmpty ? nil : text
            }
        #endif
        return nil
    }

    /// The pixel size of a PNG, decoded without the pixels (ImageIO bounds).
    static func imageSize(ofPNG data: Data) -> (width: Int, height: Int)? {
        #if canImport(ImageIO)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0
            else {
                return nil
            }
            return (width, height)
        #else
            return nil
        #endif
    }

    /// Converts TIFF bytes to PNG with ImageIO (§4.4); prefers the PNG already
    /// on the pasteboard, so this only runs without `public.png`.
    static func pngData(fromTIFF data: Data) -> Data? {
        #if canImport(ImageIO)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                return nil
            }
            let output = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    output, "public.png" as CFString, 1, nil)
            else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                return nil
            }
            return output as Data
        #else
            return nil
        #endif
    }
}

#if canImport(AppKit)
    /// `NSPasteboard.general` behind `PasteboardReading`.
    struct GeneralPasteboard: PasteboardReading, @unchecked Sendable {
        /// The shared pasteboard.
        private let pasteboard: NSPasteboard

        /// Wraps a pasteboard; `.general` in production.
        init(_ pasteboard: NSPasteboard = .general) {
            self.pasteboard = pasteboard
        }

        var changeCount: Int { pasteboard.changeCount }
        var types: [String] { (pasteboard.types ?? []).map(\.rawValue) }
        func string(forType type: String) -> String? {
            pasteboard.string(forType: NSPasteboard.PasteboardType(type))
        }
        func data(forType type: String) -> Data? {
            pasteboard.data(forType: NSPasteboard.PasteboardType(type))
        }
        @discardableResult
        func write(_ items: [(type: String, data: Data)]) -> Int {
            pasteboard.clearContents()
            for item in items {
                pasteboard.setData(item.data, forType: NSPasteboard.PasteboardType(item.type))
            }
            return pasteboard.changeCount
        }
        func writeTransient(_ items: [(type: String, data: Data)]) -> Int {
            pasteboard.clearContents()
            pasteboard.setData(
                Data(), forType: NSPasteboard.PasteboardType(PasteboardAdapter.transientType))
            for item in items {
                pasteboard.setData(item.data, forType: NSPasteboard.PasteboardType(item.type))
            }
            return pasteboard.changeCount
        }
    }
#endif

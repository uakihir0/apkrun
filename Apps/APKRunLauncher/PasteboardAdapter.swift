import CryptoKit
import Foundation
import RuntimeAPI
import RuntimeClient

#if canImport(AppKit)
    import AppKit
#endif

/// The Mac-side pasteboard adapter of desktop-integration.md §4.2 and §4.4.
///
/// Reads happen on ⌘V (`trigger = .paste`) and when a package window becomes
/// key (`trigger = .focus`), never in the background. An Android clip lands as
/// `clearContents` + the clip's types + the `io.apkrun.clip-origin` marker —
/// the marker is loop-guard signal 3, the SHA-256 digest of the normalized
/// text is signal 2, and the guest `origin`/`seq` is signal 1.

/// The minimal pasteboard surface the adapter needs, for tests.
protocol PasteboardReading: Sendable {
    /// The change counter; a read compares it to the last pushed count.
    var changeCount: Int { get }
    /// The declared type identifiers.
    var types: [String] { get }
    /// The UTF-8 payload of a type, or nil.
    func string(forType type: String) -> String?
    /// Replaces all contents with the given type payloads.
    @discardableResult
    func write(_ items: [(type: String, value: String)]) -> Int
    /// Replaces all contents as a paste-once clip (TransientType).
    @discardableResult
    func writeTransient(_ items: [(type: String, value: String)]) -> Int
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
    /// The 1 MiB text limit; longer text is truncated at a character boundary
    /// and the window shows "Only the first 1 MB was copied." (§4.4, §11.4).
    static let textByteLimit = 1_048_576

    private let pasteboard: any PasteboardReading
    /// The change count of the last clip pushed to Android.
    private(set) var lastSentChangeCount = -1
    /// The change count of the last clip the adapter itself wrote, so a
    /// marker-stripped rewrite is still recognized.
    private(set) var lastWrittenChangeCount = -1

    /// Creates an adapter over a pasteboard.
    init(pasteboard: any PasteboardReading) {
        self.pasteboard = pasteboard
    }

    /// Reads the clip to push toward Android, or nil when nothing new is there
    /// or the contents came from Android (§4.4).
    func readHostClip(trigger: ClipTrigger) -> ClipItem? {
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
        guard types.contains(Self.plainTextType),
            let text = pasteboard.string(forType: Self.plainTextType),
            !text.isEmpty
        else {
            return nil
        }
        var clipped = text
        var truncated = false
        if clipped.utf8.count > Self.textByteLimit {
            clipped = Self.truncate(clipped, to: Self.textByteLimit)
            truncated = true
        }
        let html = types.contains(Self.htmlType) ? pasteboard.string(forType: Self.htmlType) : nil
        guard let digest = Self.digest(text: clipped) else {
            return nil
        }
        lastSentChangeCount = count
        return ClipItem(
            text: clipped,
            html: html,
            image: nil,
            sensitive: types.contains(Self.concealedType),
            digest: digest,
            truncated: truncated,
            trigger: trigger
        )
    }

    /// Writes a guest clip and returns what `clipboardWritten` reports (§4.2).
    ///
    /// The write is `clearContents` + the clip's types + the origin marker.
    /// Sensitive clips use the concealed type; the transient type marks a clip
    /// the window pastes once, not a store the Mac keeps.
    @discardableResult
    func writeGuestClip(
        _ item: ClipItem,
        package: String,
        seq: UInt64,
        transient: Bool = false
    ) -> PasteboardWrite? {
        guard let text = item.text, let digest = Self.digest(text: text) else {
            return nil
        }
        var items: [(type: String, value: String)] = [
            (Self.plainTextType, text)
        ]
        if let html = item.html {
            items.append((Self.htmlType, html))
        }
        if item.sensitive {
            items.append((Self.concealedType, ""))
        }
        items.append((Self.markerType, "\(package)|\(seq)|\(digest.rawValue)"))
        let count: Int
        if transient {
            count = pasteboard.writeTransient(items)
        } else {
            count = pasteboard.write(items)
        }
        lastWrittenChangeCount = count
        lastSentChangeCount = count
        return PasteboardWrite(changeCount: count, digest: digest)
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
        @discardableResult
        func write(_ items: [(type: String, value: String)]) -> Int {
            pasteboard.clearContents()
            for item in items {
                pasteboard.setString(item.value, forType: NSPasteboard.PasteboardType(item.type))
            }
            return pasteboard.changeCount
        }
        func writeTransient(_ items: [(type: String, value: String)]) -> Int {
            pasteboard.clearContents()
            pasteboard.setString("", forType: NSPasteboard.PasteboardType(PasteboardAdapter.transientType))
            for item in items {
                pasteboard.setString(item.value, forType: NSPasteboard.PasteboardType(item.type))
            }
            return pasteboard.changeCount
        }
    }
#endif

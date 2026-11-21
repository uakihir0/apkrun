import CoreGraphics
import Foundation

/// The host-side model of the bound Android editor, for `NSTextInputClient` (input.md §5.3). It
/// holds the marked text the macOS input method set, the selection inside it, and the last cursor
/// rectangle the IME reported, in display pixels. The editor's own text is never mirrored
/// (input.md §10), so ranges are relative to the composition.
public struct TextInputModel: Sendable, Equatable {
    /// The composing text, empty when no composition is active.
    public private(set) var markedText = ""
    /// The selection inside `markedText`, in UTF-16 offsets as AppKit reports them.
    public var selectedRange: NSRange = NSRange(location: 0, length: 0)
    /// The last cursor rectangle the IME reported, in display pixels. Nil when unknown.
    public private(set) var cursorRectPx: CGRect?

    /// Creates an empty model.
    public init() {}

    /// Whether a composition is active (`NSTextInputClient.hasMarkedText`).
    public var hasMarkedText: Bool {
        !markedText.isEmpty
    }

    /// `NSTextInputClient.markedRange`: the whole composing text, or `{NSNotFound, 0}`.
    public var markedRange: NSRange {
        hasMarkedText
            ? NSRange(location: 0, length: (markedText as NSString).length)
            : NSRange(location: NSNotFound, length: 0)
    }

    /// The selection as a `TextRange` for the wire `setComposing` event (input.md §5.3). Selection
    /// offsets are relative to the composing text.
    public var selectionRange: TextRange {
        TextRange(start: Int32(clamping: selectedRange.location), end: Int32(clamping: NSMaxRange(selectedRange)))
    }

    /// `setMarkedText`: a new composition replaces the current one (input.md §5.3).
    public mutating func setMarked(text: String, selectedRange: NSRange) {
        markedText = text
        self.selectedRange = selectedRange
    }

    /// `insertText` and `unmarkText`: the composition ends.
    public mutating func clearMarked() {
        markedText = ""
        selectedRange = NSRange(location: 0, length: 0)
    }

    /// The cursor rectangle of the latest editor report, in display pixels.
    public mutating func updateCursorRect(_ rect: CGRect?) {
        cursorRectPx = rect
    }
}

/// A selection or range in editor offsets, shared with the wire types (input.md §5.3).
public struct TextRange: Sendable, Equatable, Codable {
    /// The first offset.
    public var start: Int32
    /// The offset after the last character.
    public var end: Int32

    /// Creates a range.
    public init(start: Int32, end: Int32) {
        self.start = start
        self.end = end
    }
}

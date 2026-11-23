import Foundation

@testable import GuestProtocol

/// libFuzzer entry points of GuestProtocol (test-strategy.md §7.2, #92).
package enum GuestProtocolFuzzEntries {
    /// `guest-frame-swift`: the frame decoder fed arbitrary byte streams —
    /// malformed lengths and oversized bodies must throw, never trap.
    package static func guestFrame(_ bytes: UnsafeBufferPointer<UInt8>) {
        var decoder = FrameDecoder()
        // Feed in random-sized chunks so partial frames decode too.
        var offset = 0
        while offset < bytes.count {
            let chunkSize = min(bytes.count - offset, Int(bytes[offset]) + 1)
            decoder.append(Data(bytes[offset..<(offset + chunkSize)]))
            offset += chunkSize
            while (try? decoder.nextBody()) != nil {}
        }
    }
}

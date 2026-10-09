import Foundation

/// The "no sensors" substitute for the Cuttlefish sensors host (android-image.md §7.1).
///
/// The stock sensors HAL sends `list-sensors` on hvc18 and blocks until the host
/// answers; without an answer `system_server` blocks and its Watchdog kills it.
/// Frames are a little-endian `u32` of `command | is_response << 31`, a
/// little-endian `u32` payload size, and the payload
/// (`common/libs/transport/channel.h`, `android17-release`).
struct SensorsResponder: Sendable {
    /// The frame the real `sensors_simulator` sends for an empty sensor mask:
    /// command 2 (`kUpdateHal`) with `is_response`, payload `"0\n"`.
    static let emptyMaskReply = Data([0x02, 0x00, 0x00, 0x80, 0x02, 0x00, 0x00, 0x00, 0x30, 0x0A])
    /// The HAL's maximum frame payload; larger frames mean the stream is not this protocol.
    static let maximumPayload = 64 * 1024

    private var buffer = Data()
    /// The commands seen, for diagnostics (`list-sensors`, `time:`, `set-delay:`).
    private(set) var commands: [String] = []

    /// Consumes guest bytes; returns the bytes to write back to the guest.
    mutating func consume(_ bytes: Data) -> Data {
        buffer.append(bytes)
        var reply = Data()
        while buffer.count >= 8 {
            let header = [UInt8](buffer.prefix(8))
            let size = Int(header[4]) | Int(header[5]) << 8 | Int(header[6]) << 16 | Int(header[7]) << 24
            guard size <= Self.maximumPayload else {
                buffer.removeAll()
                break
            }
            guard buffer.count >= 8 + size else {
                break
            }
            let payload = String(decoding: buffer.dropFirst(8).prefix(size), as: UTF8.self)
            buffer.removeFirst(8 + size)
            commands.append(String(payload.prefix(32)))
            if payload.hasPrefix("list-sensors") {
                reply.append(Self.emptyMaskReply)
            }
        }
        return reply
    }
}

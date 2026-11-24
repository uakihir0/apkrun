import Foundation

@testable import GraphicsCore

/// libFuzzer entry points of GraphicsCore (test-strategy.md §7.2, #92).
/// Each returns only through typed errors; a trap is a fuzz crash.
package enum GraphicsCoreFuzzEntries {
    /// `virtio-gpu-request`: the guest→host virtio-gpu command decoder.
    package static func virtioGPURequest(_ bytes: UnsafeBufferPointer<UInt8>) {
        _ = try? VirtioGPUProtocol.decodeRequest(Array(bytes))
    }

    /// `resource-table`: create/attach/unref/detach/reset driven by the
    /// input bytes; the §5.4 RiftVM limits must hold for every sequence.
    package static func resourceTable(_ bytes: UnsafeBufferPointer<UInt8>) {
        var table = ResourceTable()
        var index = 0
        func next() -> UInt32 {
            guard index + 4 <= bytes.count else { return 0 }
            let value =
                UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
            index += 4
            return value
        }
        while index + 4 <= bytes.count {
            let op = next() % 6
            let id = next()
            do {
                switch op {
                case 0:
                    try table.createHost2D(
                        id: id, format: next() % 4, width: next() % 16384,
                        height: next() % 16384)
                case 1:
                    try table.createVirgl2D(
                        id: id, format: next() % 4, width: next() % 16384,
                        height: next() % 16384)
                case 2:
                    try table.attachBacking(
                        id: id,
                        entries: [
                            VirtioGPUMemoryEntry(
                                address: UInt64(next()), length: next() % 4096 + 1)
                        ],
                        isInGuestMemory: { _ in next() % 2 == 0 })
                case 3:
                    try table.unref(id: id)
                case 4:
                    try table.detachBacking(id: id)
                default:
                    table.reset()
                }
            } catch {
                continue
            }
        }
    }
}

import GraphicsBridge
import IOSurface

/// A present target: the Metal texture of one IOSurface, imported into GL (graphics.md §6.2, #24).
///
/// Only the render thread creates, uses, and destroys a target.
protocol PresentTarget: AnyObject, Sendable {}

/// The result of waiting on a present fence.
enum PresentWaitOutcome: Equatable, Sendable {
    /// The GPU has finished the blit.
    case signaled
    /// The timeout expired first. The caller waits again (graphics.md §6.2 stall rule).
    case timedOut
    /// The fence cannot be waited on, so the frame is lost.
    case failed
}

/// The GPU completion of one present blit (graphics.md §6.2 step 4).
///
/// ANGLE validates a fence check against the current context, so the render thread checks the fence between requests,
/// with the root context current. The completion waiter asks the render thread for each check, and releases the fence
/// once it has the outcome.
protocol PresentFence: AnyObject, Sendable {
    /// Checks the blit once, without blocking. Call it on the render thread.
    func poll() -> PresentWaitOutcome
    /// Releases the fence. Call it on the render thread, after the last poll.
    func release()
}

/// The virglrenderer calls that the render thread makes (graphics.md §4.5, §5.2).
///
/// Every call runs on the render thread that owns the engine. `VirGLRenderer`
/// implements the protocol over the GraphicsBridge. Tests use a fake, which is
/// why the device logic does not need a Metal device.
protocol VirGLEngine: AnyObject {
    func capsetInfo(id: UInt32) throws(GraphicsFailure) -> GraphicsCapsetInfo
    func fillCapset(id: UInt32, version: UInt32, into buffer: inout [UInt8]) throws(GraphicsFailure)
    func createContext(id: UInt32, name: String) throws(GraphicsFailure)
    func destroyContext(id: UInt32) throws(GraphicsFailure)
    func attachResource(context: UInt32, resource: UInt32) throws(GraphicsFailure)
    func detachResource(context: UInt32, resource: UInt32) throws(GraphicsFailure)
    func submit(context: UInt32, commands: [UInt8]) throws(GraphicsFailure)
    func createResource(_ arguments: VirGLResourceArguments) throws(GraphicsFailure)
    func unrefResource(id: UInt32)
    /// Gives the renderer guest pages as the backing of `resource`. The renderer uses the pages, not a copy, until
    /// `detachBacking` or `unrefResource` (graphics.md §4.4, IR-836).
    func attachBacking(resource: UInt32, ranges: [VirGLBackingRange]) throws(GraphicsFailure)
    /// Releases the backing of `resource`, if it has any. Call while the guest pages are still mapped.
    func detachBacking(resource: UInt32)
    func transferWrite(_ transfer: VirGLTransfer, data: inout [UInt8]) throws(GraphicsFailure)
    func transferRead(_ transfer: VirGLTransfer, into data: inout [UInt8]) throws(GraphicsFailure)
    func createFence(id: UInt32, context: UInt32) throws(GraphicsFailure)
    /// Creates a present target for `surface`, which is `width` x `height` BGRA8 pixels (graphics.md §6.3).
    func createPresentTarget(surface: IOSurface, width: UInt32, height: UInt32) throws(GraphicsFailure)
        -> any PresentTarget
    /// Releases a present target. Call it before the renderer is destroyed.
    func destroyPresentTarget(_ target: any PresentTarget)
    /// Copies `sourceRect` of `resource` into the whole target, scaling when the sizes differ, and flushes. The fence
    /// signals when the GPU has finished the copy (graphics.md §6.2 steps 2 and 4).
    func presentBlit(
        resource: UInt32,
        sourceRect: VirtioGPURect,
        into target: any PresentTarget
    ) throws(GraphicsFailure) -> any PresentFence
    func poll()
    func reset() throws(GraphicsFailure)
    func destroy() throws(GraphicsFailure)
}

/// The arguments of a resource creation, as virglrenderer takes them.
struct VirGLResourceArguments: Codable, Equatable, Sendable {
    var resourceID: UInt32
    var target: UInt32
    var format: UInt32
    var bind: UInt32
    var width: UInt32
    var height: UInt32
    var depth: UInt32
    var arraySize: UInt32
    var lastLevel: UInt32
    var sampleCount: UInt32
    var flags: UInt32

    var bridgeArguments: gb_resource_args {
        gb_resource_args(
            resource_id: resourceID,
            target: target,
            format: format,
            bind: bind,
            width: width,
            height: height,
            depth: depth,
            array_size: arraySize,
            last_level: lastLevel,
            sample_count: sampleCount,
            flags: flags
        )
    }
}

/// One range of guest pages that backs a resource (graphics.md §4.4, IR-836).
///
/// The memory is the guest's RAM. It stays valid until the device resets or stops, which is also the end of the
/// renderer's use of it: the renderer releases the range before then, through `detachBacking`, `unrefResource`, or
/// the renderer's reset.
// UNCHECKED-SENDABLE: the range names guest memory that the device mapped on its queue. The render thread reads it
// only while the renderer holds the backing, and the lifetime above keeps the memory valid for that span.
struct VirGLBackingRange: Equatable, @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    let count: Int

    /// The range of `memory`, or `nil` when it is empty.
    init?(_ memory: UnsafeMutableRawBufferPointer) {
        guard let base = memory.baseAddress, memory.count > 0 else { return nil }
        self.base = base
        count = memory.count
    }
}

/// One box transfer between a resource and a host buffer (graphics.md §4.2).
///
/// The host buffer begins at the resource origin. The caller gathers or scatters
/// the guest bytes of the transfer, so the renderer always reads from offset 0.
struct VirGLTransfer: Codable, Equatable, Sendable {
    var resourceID: UInt32
    var contextID: UInt32
    var level: UInt32
    var stride: UInt32
    var layerStride: UInt32
    var x: UInt32
    var y: UInt32
    var z: UInt32
    var width: UInt32
    var height: UInt32
    var depth: UInt32

    var bridgeArguments: gb_transfer_args {
        gb_transfer_args(
            resource_id: resourceID,
            ctx_id: contextID,
            level: level,
            stride: stride,
            layer_stride: layerStride,
            x: x,
            y: y,
            z: z,
            width: width,
            height: height,
            depth: depth
        )
    }
}

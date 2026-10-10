import GraphicsBridge

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
    func transferWrite(_ transfer: VirGLTransfer, data: inout [UInt8]) throws(GraphicsFailure)
    func transferRead(_ transfer: VirGLTransfer, into data: inout [UInt8]) throws(GraphicsFailure)
    func createFence(id: UInt32, context: UInt32) throws(GraphicsFailure)
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

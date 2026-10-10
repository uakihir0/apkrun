import DiagnosticsCore
import GraphicsBridge
import Metal

/// One Android virglrenderer instance, owned and used by its render thread.
///
/// Create, use, and destroy the renderer on the same thread. Call `destroy()`
/// on that thread before releasing this value. Serialize all accesses and wait
/// for every in-flight call, including rejected off-thread calls, before
/// destroying it; do not call methods after `destroy()` succeeds. Fence
/// completions arrive through `onFenceCompleted`, on the same thread, during
/// `poll()` or another call.
public final class VirGLRenderer {
    private let logger = APKLogger(category: .renderer)
    private var renderer: OpaquePointer?
    private var retainedCallbackContext: UnsafeMutableRawPointer?

    /// Creates the ANGLE Metal display and initializes virglrenderer.
    public convenience init() throws(GraphicsFailure) {
        try self.init(onFenceCompleted: { _ in })
    }

    /// Creates the renderer. `onFenceCompleted` receives each fence that virglrenderer retires.
    init(onFenceCompleted: @escaping @Sendable (UInt32) -> Void) throws(GraphicsFailure) {
        let callbackContext = GraphicsRendererCallbackContext(onFenceCompleted: onFenceCompleted)
        let callbackPointer = Unmanaged.passRetained(callbackContext).toOpaque()
        var callbacks = gb_callbacks(
            write_fence: graphicsRendererWriteFence,
            log: graphicsRendererLog
        )
        var output: OpaquePointer?
        let status = gb_renderer_create(&callbacks, callbackPointer, &output)

        guard status == GB_OK, let output else {
            Unmanaged<GraphicsRendererCallbackContext>
                .fromOpaque(callbackPointer)
                .release()
            let failure = GraphicsFailure.initializationFailure(status: status)
            logger.error(
                "graphics renderer initialization failed: \(failure.code, .public)",
                errorCode: failure.qualifiedCode
            )
            throw failure
        }

        renderer = output
        retainedCallbackContext = callbackPointer
        logger.info("graphics renderer initialized")
    }

    /// The Metal device that ANGLE uses for its EGL display.
    public func metalDevice() throws(GraphicsFailure) -> any MTLDevice {
        guard let renderer else {
            throw GraphicsFailure.rendererOperationFailed(
                operation: "metalDevice",
                detail: "The renderer has already been destroyed."
            )
        }
        var devicePointer: UnsafeMutableRawPointer?
        try check(
            gb_renderer_metal_device(renderer, &devicePointer),
            operation: "metalDevice"
        )
        guard let devicePointer else {
            throw GraphicsFailure.rendererOperationFailed(
                operation: "metalDevice",
                detail: "ANGLE did not expose its Metal device."
            )
        }
        guard
            let device = Unmanaged<AnyObject>
                .fromOpaque(devicePointer)
                .takeUnretainedValue() as? any MTLDevice
        else {
            throw GraphicsFailure.rendererOperationFailed(
                operation: "metalDevice",
                detail: "ANGLE exposed an invalid Metal device."
            )
        }
        return device
    }

    /// Returns the maximum version and buffer size for an available capset.
    public func capsetInfo(id: UInt32) throws(GraphicsFailure) -> GraphicsCapsetInfo {
        let renderer = try live(operation: "capsetInfo")
        var maxVersion: UInt32 = 0
        var maxSizeBytes: UInt32 = 0
        let status = gb_capset_info(renderer, id, &maxVersion, &maxSizeBytes)
        try check(status, operation: "capsetInfo")
        return GraphicsCapsetInfo(maxVersion: maxVersion, maxSizeBytes: maxSizeBytes)
    }

    /// Writes a capset into a caller-owned buffer after checking its capacity.
    public func fillCapset(
        id: UInt32,
        version: UInt32,
        into buffer: inout [UInt8]
    ) throws(GraphicsFailure) {
        let renderer = try live(operation: "capsetFill")
        let status = buffer.withUnsafeMutableBufferPointer { bytes in
            gb_capset_fill(renderer, id, version, bytes.baseAddress, bytes.count)
        }
        try check(status, operation: "capsetFill")
    }

    /// Creates a guest rendering context with a nonzero host-assigned ID.
    public func createContext(id: UInt32, name: String) throws(GraphicsFailure) {
        let renderer = try live(operation: "contextCreate")
        let status = name.withCString { gb_ctx_create(renderer, id, $0) }
        try check(status, operation: "contextCreate")
    }

    /// Destroys a guest rendering context.
    public func destroyContext(id: UInt32) throws(GraphicsFailure) {
        let renderer = try live(operation: "contextDestroy")
        try check(gb_ctx_destroy(renderer, id), operation: "contextDestroy")
    }

    /// Resets all VirGL state. The caller must discard all guest-derived IDs.
    public func reset() throws(GraphicsFailure) {
        let renderer = try live(operation: "reset")
        try check(gb_renderer_reset(renderer), operation: "reset")
    }

    /// Destroys VirGL and EGL state on the render thread.
    ///
    /// The caller must first finish and synchronize every in-flight method
    /// call, including any call from another thread that will be rejected.
    public func destroy() throws(GraphicsFailure) {
        guard let renderer else { return }
        try check(gb_renderer_destroy(renderer), operation: "destroy")
        self.renderer = nil

        if let retainedCallbackContext {
            Unmanaged<GraphicsRendererCallbackContext>
                .fromOpaque(retainedCallbackContext)
                .release()
            self.retainedCallbackContext = nil
        }
        logger.info("graphics renderer destroyed")
    }

    private func live(operation: String) throws(GraphicsFailure) -> OpaquePointer {
        guard let renderer else {
            throw GraphicsFailure.rendererOperationFailed(
                operation: operation,
                detail: "The renderer has already been destroyed."
            )
        }
        return renderer
    }

    private func check(
        _ status: Int32,
        operation: String
    ) throws(GraphicsFailure) {
        guard status != GB_OK else { return }
        let failure = GraphicsFailure.operationFailure(
            status: status,
            operation: operation
        )
        logger.error(
            "graphics renderer operation failed: \(failure.code, .public)",
            errorCode: failure.qualifiedCode
        )
        throw failure
    }
}

// UNCHECKED-SENDABLE: the renderer is confined to its render thread. The engine protocol carries the calls.
extension VirGLRenderer: VirGLEngine, @unchecked Sendable {
    func createResource(_ arguments: VirGLResourceArguments) throws(GraphicsFailure) {
        let renderer = try live(operation: "resourceCreate")
        var args = arguments.bridgeArguments
        try check(gb_resource_create(renderer, &args), operation: "resourceCreate")
    }

    func unrefResource(id: UInt32) {
        guard let renderer else { return }
        gb_resource_unref(renderer, id)
    }

    func attachResource(context: UInt32, resource: UInt32) throws(GraphicsFailure) {
        let renderer = try live(operation: "contextAttachResource")
        try check(
            gb_ctx_attach_resource(renderer, context, resource),
            operation: "contextAttachResource"
        )
    }

    func detachResource(context: UInt32, resource: UInt32) throws(GraphicsFailure) {
        let renderer = try live(operation: "contextDetachResource")
        gb_ctx_detach_resource(renderer, context, resource)
    }

    func submit(context: UInt32, commands: [UInt8]) throws(GraphicsFailure) {
        let renderer = try live(operation: "submit")
        let status = commands.withUnsafeBytes { bytes in
            gb_submit(renderer, context, bytes.baseAddress, bytes.count)
        }
        try check(status, operation: "submit")
    }

    func transferWrite(_ transfer: VirGLTransfer, data: inout [UInt8]) throws(GraphicsFailure) {
        let renderer = try live(operation: "transferWrite")
        var args = transfer.bridgeArguments
        let status = data.withUnsafeMutableBytes { bytes in
            gb_transfer_write(renderer, &args, bytes.baseAddress, bytes.count)
        }
        try check(status, operation: "transferWrite")
    }

    func transferRead(_ transfer: VirGLTransfer, into data: inout [UInt8]) throws(GraphicsFailure) {
        let renderer = try live(operation: "transferRead")
        var args = transfer.bridgeArguments
        let status = data.withUnsafeMutableBytes { bytes in
            gb_transfer_read(renderer, &args, bytes.baseAddress, bytes.count)
        }
        try check(status, operation: "transferRead")
    }

    func createFence(id: UInt32, context: UInt32) throws(GraphicsFailure) {
        let renderer = try live(operation: "fenceCreate")
        try check(gb_create_fence(renderer, id, context), operation: "fenceCreate")
    }

    func poll() {
        guard let renderer else { return }
        gb_poll(renderer)
    }

    #if APKRUN_TEST_READBACK
        // DEBUG-READBACK: test-only host readback for the replay and tearing tests (graphics.md §12). It exists only in
        // builds with the TestReadback trait, and it never touches the device's counters, because the normal path has none.
        func readResourceForTest(_ transfer: VirGLTransfer, byteCount: Int) throws(GraphicsFailure) -> [UInt8] {
            let renderer = try live(operation: "readResourceForTest")
            var data = [UInt8](repeating: 0, count: byteCount)
            var args = transfer.bridgeArguments
            let status = data.withUnsafeMutableBytes { bytes in
                gb_transfer_read(renderer, &args, bytes.baseAddress, bytes.count)
            }
            try check(status, operation: "readResourceForTest")
            return data
        }
    #endif
}

/// The renderer's callback context. Callbacks run on the render thread.
private final class GraphicsRendererCallbackContext: Sendable {
    let logger = APKLogger(category: .renderer)
    let onFenceCompleted: @Sendable (UInt32) -> Void

    init(onFenceCompleted: @escaping @Sendable (UInt32) -> Void) {
        self.onFenceCompleted = onFenceCompleted
    }
}

private let graphicsRendererWriteFence:
    @convention(c) (
        UnsafeMutableRawPointer?,
        UInt32
    ) -> Void = { contextPointer, fenceID in
        guard let contextPointer else { return }
        let context = Unmanaged<GraphicsRendererCallbackContext>
            .fromOpaque(contextPointer)
            .takeUnretainedValue()
        context.onFenceCompleted(fenceID)
    }

private let graphicsRendererLog:
    @convention(c) (
        UnsafeMutableRawPointer?,
        Int32,
        UnsafePointer<CChar>?
    ) -> Void = { contextPointer, level, messagePointer in
        guard let contextPointer, let messagePointer else { return }
        let context = Unmanaged<GraphicsRendererCallbackContext>
            .fromOpaque(contextPointer)
            .takeUnretainedValue()
        let message = String(cString: messagePointer)
        switch Int(level) {
        case GB_LOG_ERROR:
            context.logger.error("VirGL: \(message, .private)")
        case GB_LOG_WARNING, GB_LOG_INFO:
            context.logger.info("VirGL: \(message, .private)")
        default:
            context.logger.debug("VirGL: \(message, .private)")
        }
    }

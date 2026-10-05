import DiagnosticsCore
import GraphicsBridge
import Metal

/// The initialization stage that failed while constructing ANGLE and VirGL.
public enum GraphicsInitStage: String, Sendable {
    /// EGL display or context setup failed.
    case egl
    /// ANGLE did not provide its Metal device.
    case metal
    /// VirGL initialization failed.
    case virgl
}

/// A typed initialization or renderer-operation failure owned by GraphicsCore.
public enum GraphicsFailure: APKRunError, Equatable {
    /// Renderer initialization failed at `stage`.
    case rendererInitFailed(stage: GraphicsInitStage, detail: String)
    /// A required library is missing from the application runtime.
    case libraryMissing(name: String)
    /// A renderer operation failed. `operation` identifies the attempted API.
    case rendererOperationFailed(operation: String, detail: String)

    /// The registered error-catalog domain for graphics failures.
    public static let domain = ErrorDomain.graphics

    /// The stable code for this failure.
    public var code: String {
        switch self {
        case .rendererInitFailed:
            "rendererInitFailed"
        case .libraryMissing:
            "libraryMissing"
        case .rendererOperationFailed:
            "rendererOperationFailed"
        }
    }

    /// The named values recorded in diagnostics for this failure.
    public var parameters: [String: ErrorParameter] {
        switch self {
        case .rendererInitFailed(let stage, let detail):
            [
                "stage": .text(stage.rawValue),
                "detail": .text(detail),
            ]
        case .libraryMissing(let name):
            ["name": .text(name)]
        case .rendererOperationFailed(let operation, let detail):
            [
                "operation": .text(operation),
                "detail": .text(detail),
            ]
        }
    }

    fileprivate static func bridgeDetail(status: Int32) -> String {
        let detailPointer = gb_status_description(status)
        return detailPointer.map(String.init(cString:)) ?? "GraphicsBridge failed."
    }

    fileprivate static func initializationFailure(status: Int32) -> GraphicsFailure {
        let detail = bridgeDetail(status: status)
        return switch Int(status) {
        case GB_E_RUNTIME_DIRECTORY_MISSING:
            .libraryMissing(name: "VirGLRuntime")
        case GB_E_LIBRARY_MISSING_VIRGL:
            .libraryMissing(name: "libvirglrenderer.1.dylib")
        case GB_E_LIBRARY_MISSING_EPOXY:
            .libraryMissing(name: "libepoxy.0.dylib")
        case GB_E_LIBRARY_MISSING_EGL:
            .libraryMissing(name: "libEGL.dylib")
        case GB_E_LIBRARY_MISSING_GLES:
            .libraryMissing(name: "libGLESv2.dylib")
        case GB_E_EGL_INITIALIZATION:
            .rendererInitFailed(stage: .egl, detail: detail)
        case GB_E_METAL_DEVICE:
            .rendererInitFailed(stage: .metal, detail: detail)
        case GB_E_VIRGL_INITIALIZATION, GB_E_RENDERER_ALREADY_EXISTS,
            GB_E_INVALID_ARGUMENT:
            .rendererInitFailed(stage: .virgl, detail: detail)
        default:
            .rendererOperationFailed(operation: "initialize", detail: detail)
        }
    }

    fileprivate static func operationFailure(
        status: Int32,
        operation: String
    ) -> GraphicsFailure {
        .rendererOperationFailed(
            operation: operation,
            detail: bridgeDetail(status: status)
        )
    }
}

/// One Android virglrenderer instance, owned and used by its render thread.
///
/// Create, use, and destroy the renderer on the same thread. Call `destroy()`
/// on that thread before releasing this value. Serialize all accesses and wait
/// for every in-flight call, including rejected off-thread calls, before
/// destroying it; do not call methods after `destroy()` succeeds.
public final class VirGLRenderer {
    private let logger = APKLogger(category: .renderer)
    private var renderer: OpaquePointer?
    private var retainedCallbackContext: UnsafeMutableRawPointer?

    /// Creates the ANGLE Metal display and initializes virglrenderer.
    public init() throws(GraphicsFailure) {
        let callbackContext = GraphicsRendererCallbackContext()
        let callbackPointer = Unmanaged.passRetained(callbackContext).toOpaque()
        var callbacks = gb_callbacks(write_fence: nil, log: graphicsRendererLog)
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
        guard let renderer else {
            throw GraphicsFailure.rendererOperationFailed(
                operation: "capsetInfo",
                detail: "The renderer has already been destroyed."
            )
        }

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
        guard let renderer else {
            throw GraphicsFailure.rendererOperationFailed(
                operation: "capsetFill",
                detail: "The renderer has already been destroyed."
            )
        }
        let status = buffer.withUnsafeMutableBufferPointer { bytes in
            gb_capset_fill(renderer, id, version, bytes.baseAddress, bytes.count)
        }
        try check(status, operation: "capsetFill")
    }

    /// Creates a guest rendering context with a nonzero host-assigned ID.
    public func createContext(id: UInt32, name: String) throws(GraphicsFailure) {
        guard let renderer else {
            throw GraphicsFailure.rendererOperationFailed(
                operation: "contextCreate",
                detail: "The renderer has already been destroyed."
            )
        }
        let status = name.withCString { gb_ctx_create(renderer, id, $0) }
        try check(status, operation: "contextCreate")
    }

    /// Destroys a guest rendering context.
    public func destroyContext(id: UInt32) throws(GraphicsFailure) {
        guard let renderer else {
            throw GraphicsFailure.rendererOperationFailed(
                operation: "contextDestroy",
                detail: "The renderer has already been destroyed."
            )
        }
        try check(gb_ctx_destroy(renderer, id), operation: "contextDestroy")
    }

    /// Resets all VirGL state. The caller must discard all guest-derived IDs.
    public func reset() throws(GraphicsFailure) {
        guard let renderer else {
            throw GraphicsFailure.rendererOperationFailed(
                operation: "reset",
                detail: "The renderer has already been destroyed."
            )
        }
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

/// The renderer has one process-owned callback context; callbacks run on its render thread.
private final class GraphicsRendererCallbackContext: Sendable {
    let logger = APKLogger(category: .renderer)
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

/// The maximum version and byte count reported for one capset.
public struct GraphicsCapsetInfo: Equatable, Sendable {
    /// The highest capset version supported by VirGL.
    public let maxVersion: UInt32
    /// The maximum number of bytes required to fill this capset.
    public let maxSizeBytes: UInt32

    /// Creates capset metadata from a renderer's reported limits.
    public init(maxVersion: UInt32, maxSizeBytes: UInt32) {
        self.maxVersion = maxVersion
        self.maxSizeBytes = maxSizeBytes
    }
}

/// Standard virglrenderer capset identifiers.
public enum GraphicsCapset: Sendable {
    /// The original VirGL capset.
    public static let virgl: UInt32 = UInt32(GB_CAPSET_VIRGL)
    /// The VirGL 2 capset.
    public static let virgl2: UInt32 = UInt32(GB_CAPSET_VIRGL2)
}
